;;; latex-to-svg-backend-core.el --- Shared parts of latex-to-svg-backend -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg-backend

;; This file is not part of GNU Emacs.

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; The parts of `latex-to-svg-backend' that do not depend on how an
;; equation is typeset: the shared options, error reporting, colors,
;; sizing, cache addressing, the display image, the placeholder, the
;; process chain, the compile outcome and the cache garbage collector.
;; The engines live in `latex-to-svg-backend-latex' and
;; `latex-to-svg-backend-ratex', the public entry point in
;; `latex-to-svg-backend'.  Load `latex-to-svg-backend', not this file.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'color)
(require 'seq)
(require 'svg)

(defgroup latex-to-svg-backend nil
  "Render LaTeX math to SVG images with `latex' + `dvisvgm' or with RaTeX.
Equations are compiled to a color- and size-independent SVG, cached
on disk by content, then tinted to the buffer foreground and scaled
to the buffer font at display time."
  :group 'tex
  :prefix "latex-to-svg-backend-")

;;;; Customization

(defcustom latex-to-svg-backend-cache-directory nil
  "Directory for cached equation SVGs and scratch compiles.
When nil, `$XDG_CACHE_HOME/emacs/latex-to-svg/' (or
`~/.cache/emacs/latex-to-svg/') is used, so equation SVGs persist across
sessions and each unique equation compiles at most once.  Because the
cache is keyed by content and is color/size-independent, it is safe to share
across every front-end and buffer."
  :type '(choice (const :tag "Default XDG cache" nil) directory)
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-cache-max-age 90
  "Delete cached equation SVGs untouched for this many days, or nil for no cap.
The garbage collector (`latex-to-svg-backend-gc') treats each SVG's
modification time as its last-use time (bumped on every load), so this
expires equations that have not been viewed within the given window.
Because the cache is keyed by content and is color/size-independent, an
expired equation simply recompiles the next time it is needed."
  :type '(choice (const :tag "No age limit" nil) (integer :tag "Days"))
  ;; Bounded blast radius: it only decides when the collector drops entries
  ;; from our own cache directory, and a dropped equation is recompiled.
  :safe (lambda (v) (or (null v) (integerp v)))
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-gc-interval 1
  "Minimum days between automatic cache collections, or nil to disable them.
An idle timer checks this cadence against an on-disk timestamp, so
`latex-to-svg-backend-gc' runs at most once per interval no matter how many
sessions share the cache (and still collects a long-lived daemon daily).
Set to nil to turn off automatic GC entirely; `latex-to-svg-backend-gc'
can always be invoked by hand."
  :type '(choice (const :tag "Disabled" nil) (number :tag "Days"))
  :safe (lambda (v) (or (null v) (numberp v)))
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-font-scale 1.0
  "Size of rendered equations relative to the buffer font.

Equation images are scaled so LaTeX's 10pt body font maps onto the
buffer's font height; this multiplier rides on top of that match.
1.0 makes equation text the same size as the surrounding text;
greater than 1 enlarges, less than 1 shrinks.  Because the match is
recomputed from the current font on each render, equations track the
buffer font across themes, faces, and text scale."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-use-placeholder nil
  "When non-nil, draw the placeholder panel instead of typesetting LaTeX.
Also used as the automatic fallback when the programs of the engine a
call asks for are unavailable (see
`latex-to-svg-backend-tools-available-p')."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-render-on-non-graphic nil
  "When non-nil, render equation images even on a non-graphical frame.

By default equations are only compiled when the selected frame is
graphical (`display-graphic-p').  In an Emacs daemon a buffer may
be rendered while a TTY frame is selected, yet later viewed in a
graphical frame; without this the equation would never have been
produced and stays raw text in the GUI too.

Set non-nil (typically in a daemon setup) to always compile the
SVG when the build supports it: it is ignored on a TTY frame (the
raw LaTeX shows) but appears as soon as a graphical frame views
the buffer.  The trade-off is that a purely terminal session then
spawns LaTeX compiles whose images it never displays."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-svg-dpi 96.0
  "Dots-per-inch Emacs's SVG renderer uses to convert points to pixels.

Used to size equation previews to the buffer font: an SVG `pt' is
rendered as `latex-to-svg-backend-svg-dpi' / 72 pixels.  librsvg (Emacs's SVG
backend) converts SVG length units at 96 DPI, so the default suits
almost all systems; override only if previews come out uniformly too
big or too small.  HiDPI is handled separately by `image-scaling-factor'
\(it scales the reference and the equation alike, so it cancels) and
does not belong here.

This replaced a per-frame `image-size' measurement that proved
unreliable on some ports (returning wildly different pixel sizes for
the same undisplayed SVG), which made preview sizing non-deterministic."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg-backend)

;;;; State

;; image-cache key = content key (sha1 of latex + preamble + style) plus the
;; display scale and tint color, via `latex-to-svg-backend--image-cache-key'.  Folding
;; scale and color in lets images at different font sizes / themes coexist, so
;; a font or theme change just adds an entry (no cache clear) and sibling
;; buffers' warm images survive.  The underlying SVG is still compiled at most
;; once per content key (the disk cache is font- AND color-independent); only
;; the cheap `create-image' is per scale/color.
(defvar latex-to-svg-backend--image-cache (make-hash-table :test 'equal)
  "In-memory map of image-cache key to rendered equation image.")

;; key -> list of waiters (see `latex-to-svg-backend--waiter') awaiting one
;; in-flight compile.  Dedupes concurrent compiles of the same equation and
;; records every consumer to notify once the SVG is ready, or to report to
;; when the compile fails.
(defvar latex-to-svg-backend--pending (make-hash-table :test 'equal)
  "In-memory map of cache key to waiters awaiting an in-flight compile.")

(defun latex-to-svg-backend--waiter (callback &optional quiet fallback)
  "Return a waiter for CALLBACK, requested from the current buffer.
A waiter is the plist (:callback CALLBACK :buffer BUFFER :quiet QUIET
:fallback FALLBACK) queued in `latex-to-svg-backend--pending'.  CALLBACK
is the caller's zero-argument function.  BUFFER is the requesting buffer,
which a failure is reported in.  QUIET non-nil reports no compile failure
for this request.  FALLBACK is nil or a function of one argument, the
waiter, that takes the request over to the fallback engine when the
compile fails because of the formula."
  (list :callback callback :buffer (current-buffer)
        :quiet quiet :fallback fallback))

;;;; Error reporting

;; Conditions already reported by `latex-to-svg-backend--warn-once', keyed
;; "CONTEXT/ERROR-SYMBOL" and valued with the time they were reported.  An
;; error the backend recovers from is never silent: the first of each kind
;; warns, so a misconfiguration is diagnosable, while a recurring one does not
;; warn once per equation.
(defvar latex-to-svg-backend--warned (make-hash-table :test 'equal)
  "Context/condition pairs already reported this session, and when.")

;; Buffer-scoped marks live with the buffer, so they are discarded when it is
;; killed and never accumulate for a long-lived process, a rename cannot re-arm
;; them, and a reopened document is genuinely a new one.
(defvar-local latex-to-svg-backend--warned-in-buffer nil
  "Alist of context/condition pairs already reported in this buffer, and when.")

(defconst latex-to-svg-backend--warn-interval 86400
  "Seconds before the same condition is reported again at the same site.
A warning from three weeks ago says nothing about whether the problem is
still there, so a mark goes stale instead of lasting for the life of the
buffer or the process.  A day is long enough that a persistent failure
costs one line in `*Warnings*' per day, and lines up with the default
`latex-to-svg-backend-gc-interval', so a cache directory the collector
cannot write reports once per collection attempt.")

(defun latex-to-svg-backend--mark-once (seen &optional scope)
  "Mark SEEN as reported and return non-nil, unless it was reported already.
SEEN is a string naming the condition.  SCOPE is as for
`latex-to-svg-backend--warn-once', which describes how often \"once\" is."
  (let* ((now (float-time))
         (last (if (eq scope 'buffer)
                   (cdr (assoc seen latex-to-svg-backend--warned-in-buffer))
                 (gethash seen latex-to-svg-backend--warned))))
    (when (or (null last)
              (> (- now last) latex-to-svg-backend--warn-interval))
      (if (eq scope 'buffer)
          (setf (alist-get seen latex-to-svg-backend--warned-in-buffer
                           nil nil #'equal)
                now)
        (puthash seen now latex-to-svg-backend--warned))
      t)))

(defun latex-to-svg-backend--warn-once (context err &optional scope)
  "Report ERR under CONTEXT once, and return nil.
For an error the backend recovers from: the recovery is reported rather than
silenced, but a recurring one does not warn per equation.  CONTEXT is a
short phrase naming what failed, e.g. \"recording cache use\".

SCOPE says how often \"once\" is.  Nil means once per session, recorded in
`latex-to-svg-backend--warned'.  `buffer' means once per buffer, marked
buffer-locally in `latex-to-svg-backend--warned-in-buffer': the display
path is entered from the buffer being rendered, so a problem that persists
is re-reported for each document opened, rather than once for the life of a
process -- an Emacs server runs for weeks, and a single warning there is
easily missed or long stale.  Equations within one buffer still share one
warning.

Callers reached from a process sentinel or an idle timer must leave SCOPE
nil: the buffer current there is unrelated to the equation (our own process
output buffer, or whatever the timer interrupted), so marking it would both
misattribute the diagnosis and warn far too often.  A compile failure is
the exception: its waiters record the requesting buffer (see
`latex-to-svg-backend--waiter'), and `latex-to-svg-backend--report-failure'
marks that buffer.

Either way a mark goes stale after `latex-to-svg-backend--warn-interval',
so a condition that is still occurring is reported again rather than
resting on a warning from weeks ago."
  (when (latex-to-svg-backend--mark-once
         (format "%s/%s" context (car err)) scope)
    (display-warning 'latex-to-svg-backend
                     (format "%s: %s" context (error-message-string err))
                     :warning))
  nil)

;;;; Colors and appearance

(defun latex-to-svg-backend--color-to-hex (color fallback)
  "Return COLOR (a name or `#rrggbb') as a `#rrggbb' string, or FALLBACK.
FALLBACK is returned when COLOR is not a string or can't be resolved
to RGB (e.g. an `unspecified-*' sentinel, or off a window system)."
  ;; `color-name-to-rgb' returns nil for an unknown name or an
  ;; `unspecified-*' sentinel -- no error, just no color.  It signals only
  ;; when the display cannot resolve even white: it normalizes against
  ;; `(float (car (color-values "#ffffffffffff")))', so a colorless display
  ;; gives `wrong-type-argument'.  Report that once; either way, fall back.
  (if-let* (((stringp color))
            (rgb (condition-case err
                     (color-name-to-rgb color)
                   (wrong-type-argument
                    (latex-to-svg-backend--warn-once "resolving a color" err 'buffer)))))
      (apply #'color-rgb-to-hex (append rgb '(2)))
    fallback))

(defun latex-to-svg-backend--svg-color (face attribute fallback)
  "Return FACE's ATTRIBUTE color as a `#rrggbb' string, or FALLBACK.

ATTRIBUTE is `:foreground' or `:background'.  FALLBACK is returned
when the attribute is unspecified or can't be resolved to RGB
\(e.g. on a terminal that reports symbolic colors)."
  (latex-to-svg-backend--color-to-hex
   (face-attribute face attribute nil 'default) fallback))

(defun latex-to-svg-backend-foreground-color ()
  "Return the `#rrggbb' foreground equations should be tinted with now.
Resolved from the `default' face of the selected frame."
  (latex-to-svg-backend--svg-color 'default :foreground "#000000"))

(defun latex-to-svg-backend--current-colors ()
  "Return the (FOREGROUND . BACKGROUND) equations should render for now.
Both are `#rrggbb' strings resolved from the `default' face."
  (cons (latex-to-svg-backend-foreground-color)
        (latex-to-svg-backend--svg-color 'default :background "#ffffff")))

(defun latex-to-svg-backend--font-height ()
  "Return the selected frame's default font pixel height, or nil.
Nil off a graphical frame: there is nothing to measure there, and the
backend deliberately does not search for another frame (a graphical frame
in `frame-list' may be an invisible child frame).  Callers that know the
buffer's real display frame measure it there and pass `:font-height'
instead.

Also nil when the font cannot be measured: on a graphical frame
`default-font-height' reads `font-info', which reports nil for a font it
cannot open, and then signals `wrong-type-argument'.  That is reported once
\(`latex-to-svg-backend--warn-once') and treated as an unknown height, so
sizing is deferred rather than guessed."
  (and (display-graphic-p)
       (condition-case err
           (default-font-height)
         (wrong-type-argument
          (latex-to-svg-backend--warn-once "measuring the buffer font" err 'buffer)))))

(defun latex-to-svg-backend-appearance (&optional font-height)
  "Return the appearance signature equations should render for now.
A list (FOREGROUND BACKGROUND FONT-HEIGHT): the colors equations
are tinted with (see `latex-to-svg-backend--current-colors') and the buffer
font pixel height they are sized to.  FONT-HEIGHT, when non-nil, is
that height (a front-end that knows the buffer's actual display frame
measures it there and passes it, so the signature matches the render);
nil falls back to the selected frame's `default-font-height', or nil
off a graphical frame.  Front-ends compare this against the value
stored at their last render to detect a color *or* font-size change
and refresh."
  (let ((colors (latex-to-svg-backend--current-colors)))
    (list (car colors) (cdr colors)
          (or font-height (latex-to-svg-backend--font-height)))))

;;;; Capability

(defun latex-to-svg-backend-available-p ()
  "Return non-nil when equation images should be produced.

Requires SVG image support in this Emacs build, plus either a
graphical selected frame or `latex-to-svg-backend-render-on-non-graphic'
\(the daemon / mixed TTY+GUI case — the image is ignored on a TTY
frame but shows once a graphical frame views the buffer)."
  (and (image-type-available-p 'svg)
       (or (display-graphic-p)
           latex-to-svg-backend-render-on-non-graphic)))

;;;; Cache addressing

(defun latex-to-svg-backend--cache-dir ()
  "Return the root cache directory, creating it if needed.
Honours `latex-to-svg-backend-cache-directory', else `$XDG_CACHE_HOME'
\(or `~/.cache') under `emacs/latex-to-svg/'.  Files are organised into
`svg/' (sharded equation SVGs + sidecars) and `fmt/' (precompiled
preambles) subdirectories, plus the `gc-timestamp' housekeeping file."
  (let ((dir (or latex-to-svg-backend-cache-directory
                 (expand-file-name
                  "emacs/latex-to-svg/"
                  (or (getenv "XDG_CACHE_HOME")
                      (expand-file-name "~/.cache"))))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun latex-to-svg-backend--subdir (name)
  "Return subdirectory NAME under the cache directory, creating it."
  (let ((dir (expand-file-name name (latex-to-svg-backend--cache-dir))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun latex-to-svg-backend--shard-dir (key)
  "Return the shard subdirectory holding KEY's cache files, creating it.
SVGs live under the `svg/' subdirectory, sharded into 256 buckets by the
first two characters of the (hex) content KEY, so no single directory
accumulates every equation (cf. Git's object store or org-persist's
cache).  All of KEY's files — `.svg', `.eld', `.log' — live together in
`svg/<XX>/'."
  (latex-to-svg-backend--subdir (concat "svg/" (substring key 0 2))))

(defun latex-to-svg-backend--svg-file (key)
  "Return the cache SVG path for KEY (inside its shard subdirectory)."
  (expand-file-name (concat key ".svg")
                    (latex-to-svg-backend--shard-dir key)))

(defun latex-to-svg-backend--meta-file (key)
  "Return the compile-metadata sidecar path for KEY (a `.eld' next to the SVG)."
  (expand-file-name (concat key ".eld")
                    (latex-to-svg-backend--shard-dir key)))

(defun latex-to-svg-backend--log-file (key)
  "Return the path of KEY's saved compile log (a `.log' next to the SVG)."
  (expand-file-name (concat key ".log")
                    (latex-to-svg-backend--shard-dir key)))

(defun latex-to-svg-backend--touch (file)
  "Bump FILE's modification time to now (a last-use hint for GC).
`latex-to-svg-backend-gc' treats the SVG mtime as the equation's last-use
time, so this is called whenever a cached SVG is (re)loaded.

Signals `file-missing' when FILE is gone -- the caller treats that as a
cache miss (see `latex-to-svg-backend--cached-image').  Any other refusal
by the filesystem is reported once (`latex-to-svg-backend--warn-once') and
then tolerated: the mtime only orders GC, so an entry owned by another
user (a cache populated once under sudo) or on a read-only mount is left
untouched, ages out, and recompiles."
  (condition-case err
      (set-file-times file)
    ;; A collected entry belongs to the caller, which turns it into a miss.
    (file-missing (signal (car err) (cdr err)))
    (file-error
     (latex-to-svg-backend--warn-once "recording cache use" err 'buffer))))

;;;; Scale

(defun latex-to-svg-backend--svg-px-per-pt ()
  "Return how many pixels Emacs renders one SVG point as.
A constant derived from `latex-to-svg-backend-svg-dpi' (SVG `pt' = dpi/72 px).
Not measured — see `latex-to-svg-backend-svg-dpi' for why."
  (/ latex-to-svg-backend-svg-dpi 72.0))

(defun latex-to-svg-backend-display-scale (&optional rescale-by font-height)
  "Return the `create-image' :scale that sizes equations to the buffer font.

Maps the LaTeX document's 10pt body font (the `standalone' default,
compiled at dvisvgm scale 1, so 10pt of LaTeX = 10 SVG points) onto
the buffer's font pixel height, times `latex-to-svg-backend-font-scale'.  An
equation's displayed font height is (10 * px-per-pt * scale) px, so
scale = target * font-scale / (10 * px-per-pt), where px-per-pt is the
deterministic `latex-to-svg-backend-svg-dpi' / 72.

RESCALE-BY (default 1.0) is a per-call multiplier on top of the global
`latex-to-svg-backend-font-scale'; a front-end uses it to size, say, display
equations slightly larger than inline ones, without touching the
global base.

The target font height comes from FONT-HEIGHT when given -- a front-end
that knows the buffer's actual display frame measures `default-font-height'
there and passes it, so sizing never depends on which frame happens to be
selected.  Otherwise the selected frame is measured, but only when it is
graphical (so a buffer-local text scale is honoured).  Returns nil when
no height is known (no FONT-HEIGHT and a non-graphical selected frame,
e.g. an async/daemon render of a buffer shown nowhere): the backend has
nothing trustworthy to size against, so the caller should defer building
the display image until the buffer is shown -- the on-disk SVG is size-
independent, so it can be compiled now and sized later with no recompile."
  (when-let* ((target (or font-height (latex-to-svg-backend--font-height))))
    (/ (* target latex-to-svg-backend-font-scale (or rescale-by 1.0))
       (* 10.0 (latex-to-svg-backend--svg-px-per-pt)))))

;;;; Image build

(defun latex-to-svg-backend--pad-box (padding)
  "Normalize PADDING to a (TOP RIGHT BOTTOM LEFT) list of pt, or nil.
PADDING is either a number -- the same padding on all four sides -- or a
list of one to four numbers read in CSS order: (ALL), (VERTICAL
HORIZONTAL), (TOP HORIZONTAL BOTTOM), (TOP RIGHT BOTTOM LEFT).  So
\(0 0 0 6) is a left gutter and nothing else.

Returns nil when there is nothing to pad (PADDING nil, or every side 0),
so a caller can test the result directly, and is idempotent on its own
output, so one value can be normalized where the cache key is built and
again where the geometry is applied.  Signals an error for any other
shape: a malformed spec is a caller bug, and quietly dropping the
padding would draw a box that merely looks wrong."
  (let ((box (cond
              ((null padding) nil)
              ((numberp padding) (list padding padding padding padding))
              ((and (consp padding) (seq-every-p #'numberp padding))
               (pcase padding
                 (`(,all) (list all all all all))
                 (`(,vertical ,horizontal)
                  (list vertical horizontal vertical horizontal))
                 (`(,top ,horizontal ,bottom)
                  (list top horizontal bottom horizontal))
                 (`(,top ,right ,bottom ,left)
                  (list top right bottom left)))))))
    (unless (or box (null padding))
      (error "Invalid padding %S: want a number or a list of 1-4 numbers"
             padding))
    (when (seq-some (lambda (side) (< side 0)) box)
      (error "Invalid padding %S: a side cannot be negative" padding))
    ;; All-zero is "no padding": let the caller skip the whole rewrite (and
    ;; keep `create-image' compositing the background instead of a `<rect>').
    (unless (seq-every-p #'zerop box) box)))

(defun latex-to-svg-backend--pad-svg (data pad background)
  "Expand DATA's SVG viewport by PAD on each side; fill BACKGROUND behind.
PAD is a padding spec as accepted by `latex-to-svg-backend--pad-box' (a
number for all four sides, or a list of one to four numbers in CSS
order), in the SVG's own units (pt, at dvisvgm `--scale=1'), so it
scales with the equation when the image is displayed.  The root `<svg>'
`width'/`height'/`viewBox' grow by the horizontal and the vertical sides
and the origin shifts by the left/top sides; when BACKGROUND (a color
string) is non-nil, a filled `<rect>' covering the padded viewport is
inserted behind the content so the box color extends the padding beyond
the ink.  Returns DATA unchanged if there is nothing to pad, or if the
root tag can't be parsed (defensive: never break rendering over a
padding request)."
  (if-let* ((box (latex-to-svg-backend--pad-box pad))
            ((string-match "<svg\\b[^>]*>" data))
            (beg (match-beginning 0))
            (end (match-end 0))
            (tag (match-string 0 data))
            ((string-match "\\bwidth='\\([0-9.eE+-]+\\)pt'" tag))
            (w (string-to-number (match-string 1 tag)))
            ((string-match "\\bheight='\\([0-9.eE+-]+\\)pt'" tag))
            (h (string-to-number (match-string 1 tag)))
            ((string-match
              (concat "\\bviewBox='\\([0-9.eE+-]+\\) \\([0-9.eE+-]+\\) "
                      "\\([0-9.eE+-]+\\) \\([0-9.eE+-]+\\)'")
              tag))
            (vx (string-to-number (match-string 1 tag)))
            (vy (string-to-number (match-string 2 tag)))
            (vw (string-to-number (match-string 3 tag)))
            (vh (string-to-number (match-string 4 tag))))
      (pcase-let* ((`(,top ,right ,bottom ,left) box)
                   (nx (- vx left)) (ny (- vy top))
                   (nw (+ vw left right)) (nh (+ vh top bottom))
                   (new-tag tag)
                   (rect (if background
                             (format "<rect x='%s' y='%s' width='%s' height='%s' fill='%s'/>"
                                     nx ny nw nh background)
                           "")))
        (setq new-tag (replace-regexp-in-string
                       "\\bwidth='[0-9.eE+-]+pt'"
                       (format "width='%spt'" (+ w left right)) new-tag nil t)
              new-tag (replace-regexp-in-string
                       "\\bheight='[0-9.eE+-]+pt'"
                       (format "height='%spt'" (+ h top bottom)) new-tag nil t)
              new-tag (replace-regexp-in-string
                       "\\bviewBox='[^']*'"
                       (format "viewBox='%s %s %s %s'" nx ny nw nh) new-tag nil t))
        (concat (substring data 0 beg) new-tag rect (substring data end)))
    data))

(defun latex-to-svg-backend--load-svg-image (file &optional scale color background padding)
  "Return an SVG image from FILE, tinted COLOR and sized to the buffer font.
The on-disk SVG emits its default ink as the literal token
`currentColor' (dvisvgm `--currentcolor'); when COLOR (a `#rrggbb'
string) is given it is substituted in, so the equation matches the
buffer foreground without recompiling.  Scaled by SCALE (default
`latex-to-svg-backend-display-scale') so the body font matches the
surrounding text, and centred vertically for inline display.

The SVG is transparent; BACKGROUND, when non-nil (a color string),
is painted behind it without recompiling.  Nil (the default) keeps
the equation transparent so it blends into the buffer.  PADDING grows
the SVG viewport (via `latex-to-svg-backend--pad-svg'), so the
BACKGROUND box extends beyond the ink; it is a number of pt for all
four sides or a list of one to four numbers in CSS order (see
`latex-to-svg-backend--pad-box'), and it scales with the equation.
With PADDING the box is baked into the SVG (a `<rect>'); without it
BACKGROUND is applied as `create-image' `:background'."
  (let ((data (with-temp-buffer
                (insert-file-contents file)
                (buffer-string)))
        (pad (latex-to-svg-backend--pad-box padding)))
    (when color
      (setq data (replace-regexp-in-string "currentColor" color data t t)))
    (when pad
      (setq data (latex-to-svg-backend--pad-svg data pad background)))
    (apply #'create-image data 'svg t
           :scale (or scale 1.0)
           :ascent 'center
           ;; With padding the box is a baked-in <rect>; otherwise let
           ;; `create-image' composite the background behind the SVG.
           (and background (not pad) (list :background background)))))

(defun latex-to-svg-backend--image-cache-key (key scale color &optional background padding)
  "Return the image-cache key for KEY at SCALE, COLOR, BACKGROUND, PADDING.
PADDING should be normalized (`latex-to-svg-backend--pad-box') before it
is keyed on, so that 6 and (6 6 6 6) name one entry rather than two.
KEY names the font- and color-independent on-disk SVG; the cached
image object bakes in a display `:scale', a tint COLOR, an optional
BACKGROUND box, and its PADDING, so the in-memory key adds all four.
Images at different font sizes, tints, box colors, or paddings coexist,
so any such change just creates a new entry — no cache clearing, and a
sibling buffer's warm images survive."
  (format "%s@%s@%s@%s@%s" key scale color background padding))

(defun latex-to-svg-backend--cached-image (key &optional rescale-by color background padding font-height)
  "Return the rendered image for content KEY at the current font and color.
Checks the in-memory cache (keyed by KEY, the display scale, the tint
color, the box background, and PADDING via
`latex-to-svg-backend--image-cache-key', so each variant has its own image),
else loads KEY's on-disk SVG and caches a freshly scaled, tinted image.
RESCALE-BY (default 1.0) multiplies the display scale (see
`latex-to-svg-backend-display-scale') and, via the scale, feeds the cache key,
so different per-call sizes of the same equation coexist.  FONT-HEIGHT is
passed through to `latex-to-svg-backend-display-scale' (the buffer font pixel
height measured by the caller); COLOR (a color string) overrides the
tint, nil follows the buffer foreground
\(`latex-to-svg-backend-foreground-color').  BACKGROUND (a color string) paints
a box behind the equation; nil (the default) keeps it transparent.
PADDING (pt) grows the BACKGROUND box beyond the ink.  All apply at
display time only — same on-disk SVG, no recompile — and fold into the
cache key so variants coexist.  Returns nil when the SVG isn't on disk
yet (its compile hasn't finished) OR when no font height is known (see
`latex-to-svg-backend-display-scale'): with no trustworthy size the caller
should defer to display time rather than size against a guess."
  (when-let* ((scale (latex-to-svg-backend-display-scale rescale-by font-height)))
    (let* ((color (latex-to-svg-backend--color-to-hex
                   (or color (latex-to-svg-backend-foreground-color)) "#000000"))
           ;; Resolve BACKGROUND to `#rrggbb' too: with padding it is baked
           ;; into the SVG as a `<rect fill=...>', where an Emacs/X11 name
           ;; (e.g. "gray97") is not valid; fall back to the original string
           ;; if unresolvable (a valid CSS name / hex passes through).
           (background (and background
                            (latex-to-svg-backend--color-to-hex background background)))
           ;; Normalize the padding spec once: the cache key is built from it
           ;; too, and 6 and (6 6 6 6) are the same box -- they must not
           ;; occupy two entries.
           (padding (latex-to-svg-backend--pad-box padding))
           (image-key (latex-to-svg-backend--image-cache-key
                       key scale color background padding)))
      (or (gethash image-key latex-to-svg-backend--image-cache)
          (let ((file (latex-to-svg-backend--svg-file key)))
            (when (file-exists-p file)
              ;; The cache is shared across sessions, so another session's GC
              ;; can collect the entry between the check above and the read
              ;; below.  That is a miss -- the caller recompiles -- not an
              ;; error to raise from the display path.
              (condition-case err
                  (progn
                    ;; Record the access for the LRU garbage collector.
                    (latex-to-svg-backend--touch file)
                    (puthash image-key
                             (latex-to-svg-backend--load-svg-image
                              file scale color background padding)
                             latex-to-svg-backend--image-cache))
                (file-missing
                 (latex-to-svg-backend--warn-once
                  "cache entry collected while rendering" err 'buffer)))))))))

;;;; Placeholder

(defun latex-to-svg-backend--placeholder (latex)
  "Return a placeholder SVG image boxing the raw LATEX, or nil.

This does NOT typeset LATEX — it draws the source inside a bordered
panel.  Used when `latex-to-svg-backend-use-placeholder' is set or the
toolchain is unavailable, so math still has a visible (if un-typeset)
rendering.  Returns nil when equations aren't renderable (see
`latex-to-svg-backend-available-p'), so callers fall back to the raw text.

LATEX is the equation source with the surrounding delimiters
already stripped, e.g. \"E=mc^2\"."
  (when (latex-to-svg-backend-available-p)
    (let* ((lines (split-string latex "\n"))
           ;; `frame-char-width' / `-height' give per-char pixel
           ;; dimensions on a graphical frame and stay robust off it
           ;; (unlike `default-font-width', which calls `font-info' and
           ;; errors with no live font).  Good enough for placeholder
           ;; sizing; real typesetting will set its own dimensions.
           (char-w (frame-char-width))
           (char-h (frame-char-height))
           (pad char-h)
           (badge-h char-h)
           (text-w (* char-w (apply #'max 1 (mapcar #'length lines))))
           (width (+ text-w (* 2 pad)))
           (height (+ badge-h (* char-h (length lines)) (* 2 pad)))
           (fg (latex-to-svg-backend--svg-color 'default :foreground "#000000"))
           (border (latex-to-svg-backend--svg-color 'shadow :foreground "#888888"))
           (panel (latex-to-svg-backend--svg-color 'default :background "#f4f4f4"))
           (svg (svg-create width height)))
      (svg-rectangle svg 0 0 width height
                     :rx (/ char-h 2)
                     :fill panel
                     :stroke border
                     :stroke-width 1)
      (svg-text svg "tex"
                :x pad
                :y (* badge-h 0.85)
                :font-size (* badge-h 0.7)
                :font-style "italic"
                :fill border)
      (seq-do-indexed
       (lambda (line i)
         (svg-text svg (if (string-empty-p line) " " line)
                   :x pad
                   :y (+ badge-h pad (* char-h (1+ i)) (- (/ char-h 4)))
                   :font-family "monospace"
                   :font-size char-h
                   :fill fg))
       lines)
      (svg-image svg :scale 1.0 :ascent 'center))))

;;;; Process chain

(defun latex-to-svg-backend--process-output (buffer)
  "Return BUFFER's process output as an unpropertized string."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun latex-to-svg-backend--append-process-log (buffer message)
  "Append MESSAGE as a line to process log BUFFER when possible.
Diagnostics are best-effort: a killed, read-only, or otherwise
unwritable BUFFER must never prevent the process chain from settling."
  (when (buffer-live-p buffer)
    (condition-case nil
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (unless (bolp)
              (insert "\n"))
            (insert message)
            (unless (string-suffix-p "\n" message)
              (insert "\n"))))
      (error nil))))

(defun latex-to-svg-backend--start-process
    (stage command dir output-buffer sentinel)
  "Start STAGE directly with argv COMMAND in DIR.
Send stdout and stderr to OUTPUT-BUFFER and install SENTINEL.  No
shell is involved, so this is independent of `shell-file-name'."
  (latex-to-svg-backend--append-process-log
   output-buffer (format "[%s] %S" stage command))
  (let ((default-directory (file-name-as-directory dir)))
    (make-process
     :name (format "latex-to-svg-backend-%s" stage)
     :buffer output-buffer
     :command command
     :connection-type 'pipe
     :noquery t
     :sentinel sentinel)))

(defun latex-to-svg-backend--run-process-chain
    (dir output-buffer stages done)
  "Run STAGES sequentially in DIR, logging to OUTPUT-BUFFER, then call DONE.
Each element of STAGES is (NAME COMMAND OUTPUT-FILE), where COMMAND
is an argv list passed directly to `make-process'.  Each stage's
terminal status, exit status, and sentinel event are logged to
OUTPUT-BUFFER.  A stage succeeds only when it exits with status zero
and OUTPUT-FILE exists.  DONE is called once with non-nil on complete
success and nil on any failed exit, signal, missing output, or process
startup error.  On a failed exit DONE gets a second argument, the cons
\(STAGE . EXIT-STATUS): the program ran and reported the failure itself,
which an engine reads to tell a formula it rejects from a crash."
  (cl-labels
      ((run
        (remaining)
        (if (null remaining)
            (funcall done t)
          (pcase-let* ((`(,stage ,command ,output-file) (car remaining))
                       (settled nil))
            (condition-case err
                (latex-to-svg-backend--start-process
                 stage command dir output-buffer
                 (lambda (process event)
                   (let ((status (process-status process)))
                     (when (and (not settled)
                                (memq status '(exit signal)))
                       (setq settled t)
                       (let* ((exit-status (process-exit-status process))
                              (output-exists (file-exists-p output-file)))
                         (let ((print-escape-newlines t))
                           (latex-to-svg-backend--append-process-log
                            output-buffer
                            (format "[%s] status=%s exit-status=%d event=%S"
                                    stage status exit-status event)))
                         (when (and (eq status 'exit)
                                    (zerop exit-status)
                                    (not output-exists))
                           (latex-to-svg-backend--append-process-log
                            output-buffer
                            (format "[%s] expected output missing: %S"
                                    stage output-file)))
                         (cond
                          ((and (eq status 'exit)
                                (zerop exit-status)
                                output-exists)
                           (run (cdr remaining)))
                          ((and (eq status 'exit)
                                (not (zerop exit-status)))
                           (funcall done nil (cons stage exit-status)))
                          (t (funcall done nil))))))))
              (error
               (latex-to-svg-backend--append-process-log
                output-buffer
                (format "[%s] failed to start: %s"
                        stage (error-message-string err)))
               (funcall done nil)))))))
    (run stages)))

;;;; Compile outcome

(defun latex-to-svg-backend--engine-name (engine)
  "Return the name of ENGINE (`latex', nil, or `ratex') for a message."
  (pcase-exhaustive engine
    ((or 'nil 'latex) "LaTeX")
    ('ratex "RaTeX")))

(defun latex-to-svg-backend--notify-pending (key)
  "Call every callback queued for KEY (see `latex-to-svg-backend--enqueue').
Called once KEY's SVG is in the cache.  A callback that signals is
reported and does not keep the others from running."
  (dolist (waiter (gethash key latex-to-svg-backend--pending))
    (condition-case cb-err
        (funcall (plist-get waiter :callback))
      (error
       (message "latex-to-svg-backend: callback error: %S" cb-err)))))

(defun latex-to-svg-backend--report-failure (key latex engine &optional buffer)
  "Warn that ENGINE could not compile LATEX, whose content key is KEY.
Once per equation per BUFFER, the buffer that requested it, which the
warning names; with no BUFFER, once per equation per session (see
`latex-to-svg-backend--warn-once' for how long \"once\" lasts).  The
warning links to KEY's saved log when there is one."
  (let ((seen (concat "compile failed/" key)))
    (when (if buffer
              (with-current-buffer buffer
                (latex-to-svg-backend--mark-once seen 'buffer))
            (latex-to-svg-backend--mark-once seen))
      (let ((log (latex-to-svg-backend--log-file key)))
        (display-warning
         'latex-to-svg-backend
         (format "%s compile failed%s for: %s\nSee log: %s"
                 (latex-to-svg-backend--engine-name engine)
                 (if buffer (format " in %s" (buffer-name buffer)) "")
                 (truncate-string-to-width latex 60 nil nil t)
                 (if (file-exists-p log) log "(no log available)"))
         :warning)
        (when (and (file-exists-p log) (get-buffer "*Warnings*"))
          (with-current-buffer "*Warnings*"
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (save-excursion
                (when (search-backward log nil t)
                  (make-text-button (point) (+ (point) (length log))
                                    'action (lambda (_) (find-file log))
                                    'help-echo "Open the compile log"))))))))))

(defun latex-to-svg-backend--record-failure (key)
  "Record in KEY's `.eld' sidecar that the formula failed to compile.
The record is `(:failed t)'.  A request that finds it does not compile
again (see `latex-to-svg-backend'), until
`latex-to-svg-backend-invalidate' deletes it.  Runs in the compile
sentinel, so a sidecar that cannot be written is reported once and the
equation is simply compiled again next time."
  (condition-case err
      (with-temp-file (latex-to-svg-backend--meta-file key)
        (prin1 '(:failed t) (current-buffer)))
    (file-error
     (latex-to-svg-backend--warn-once "recording a failed compile" err))))

(defun latex-to-svg-backend--compile-failed
    (key latex dir &optional process-output engine formula-fault)
  "Handle a failed compile of LATEX by ENGINE for KEY.
DIR is the scratch directory containing equation.log when LaTeX
created one.  PROCESS-OUTPUT is the captured stdout and stderr from
the engine's processes.  A persistent log containing the
available diagnostics is written to the cache directory.

FORMULA-FAULT non-nil says the engine rejected the formula itself, so
compiling it again would fail again: the failure is recorded (see
`latex-to-svg-backend--record-failure'), and each waiter with a
fallback (see `latex-to-svg-backend--waiter') is handed to it.  A
missing program, a crash or a killed process is not the formula's
fault, so it is not recorded and the next request compiles again.

Every other waiter that is not quiet gets a warning in its requesting
buffer, linking to the log (see `latex-to-svg-backend--report-failure').
A buffer killed before the compile ended is skipped; when no requesting
buffer is left, the warning is once per session.

The log is copied byte-for-byte (`raw-text' in and out): a TeX log
echoing an unencodable Unicode character would otherwise make
`write-region' prompt for a coding system from a background compile."
  (let* ((log-src (expand-file-name "equation.log" dir))
         (log-dst (latex-to-svg-backend--log-file key))
         (have-tex-log (file-exists-p log-src))
         (have-output (not (string-empty-p (or process-output ""))))
         (reported nil)
         (orphaned nil))
    (when (or have-tex-log have-output)
      (let ((coding-system-for-read 'raw-text)
            (coding-system-for-write 'raw-text))
        (with-temp-file log-dst
          (when have-tex-log
            (insert-file-contents log-src)
            (goto-char (point-max))
            (unless (bolp)
              (insert "\n")))
          (when have-output
            (when have-tex-log
              (insert "\n--- process output ---\n"))
            (insert process-output)))))
    (when formula-fault
      (latex-to-svg-backend--record-failure key))
    (dolist (waiter (gethash key latex-to-svg-backend--pending))
      (let ((fallback (plist-get waiter :fallback))
            (buffer (plist-get waiter :buffer)))
        (cond
         ((and formula-fault fallback)
          ;; The fallback's own waiter has none, so a failure there is
          ;; reported instead of falling back again.
          (condition-case fb-err
              (funcall fallback (plist-put (copy-sequence waiter) :fallback nil))
            (error
             (message "latex-to-svg-backend: fallback error: %S" fb-err))))
         ((plist-get waiter :quiet))
         ((buffer-live-p buffer)
          (latex-to-svg-backend--report-failure key latex engine buffer)
          (setq reported t))
         (t (setq orphaned t)))))
    (when (and orphaned (not reported))
      (latex-to-svg-backend--report-failure key latex engine))))

;;;; Cache maintenance (garbage collection)

(defconst latex-to-svg-backend--entry-extensions '(".svg" ".eld" ".log")
  "Extensions of the files a cache entry can have, the leading one first.
An entry is the files named after one content key.  A compiled equation
has an `.svg'; one whose compile failed has no `.svg', only its `.log'
and, when the formula was at fault, its `.eld' failure record.")

(defun latex-to-svg-backend--entry-lead (file)
  "Return the file that dates the cache entry FILE belongs to, or nil.
That is the entry's first existing file in the order of
`latex-to-svg-backend--entry-extensions': its SVG, whose mtime is bumped
on every load, else its sidecar, else its log."
  (let ((base (file-name-sans-extension file)))
    (seq-some (lambda (ext)
                (let ((f (concat base ext)))
                  (and (file-exists-p f) f)))
              latex-to-svg-backend--entry-extensions)))

(defun latex-to-svg-backend--delete-entry (file)
  "Delete the cache entry FILE belongs to: its `.svg', `.eld' and `.log'.
Return the bytes freed."
  (let ((base (file-name-sans-extension file))
        (freed 0))
    (dolist (ext latex-to-svg-backend--entry-extensions)
      (let ((f (concat base ext)))
        (when (file-exists-p f)
          (cl-incf freed (or (file-attribute-size (file-attributes f)) 0))
          ;; No guard needed: `delete-file' ignores ENOENT, so another session
          ;; collecting the same shared cache entry first is not an error --
          ;; while a real one (unwritable cache) still signals.
          (delete-file f))))
    freed))

(defun latex-to-svg-backend--gc-stamp-file ()
  "Return the path of the file recording the last GC time."
  (expand-file-name "gc-timestamp" (latex-to-svg-backend--cache-dir)))

(defun latex-to-svg-backend--last-gc-time ()
  "Return the `float-time' of the last recorded GC, or 0 if never / unreadable.
An unusable stamp is reported once and treated as \"never collected\", which
is self-healing: the next GC runs and rewrites the stamp."
  (let ((f (latex-to-svg-backend--gc-stamp-file)))
    (or (and (file-readable-p f)
             (condition-case err
                 (let ((stamp (with-temp-buffer
                                (insert-file-contents f)
                                (read (current-buffer)))))
                   (if (numberp stamp)
                       stamp
                     ;; Parsed, but not a time -- corrupt just the same.
                     (latex-to-svg-backend--warn-once
                      "reading the GC timestamp"
                      (list 'invalid-read-syntax f))))
               ((end-of-file invalid-read-syntax file-error)
                (latex-to-svg-backend--warn-once
                 "reading the GC timestamp" err))))
        0)))

(defun latex-to-svg-backend--record-gc-time ()
  "Persist the current time as the last GC time (for the daily cadence).
A cache directory that cannot be written is reported once; the cadence is
then simply not persisted, so the next idle check collects again -- harmless,
since collecting an already-collected cache frees nothing."
  (condition-case err
      (with-temp-file (latex-to-svg-backend--gc-stamp-file)
        (prin1 (float-time) (current-buffer)))
    (file-error
     (latex-to-svg-backend--warn-once "recording the GC timestamp" err))))

;;;###autoload
(defun latex-to-svg-backend-gc ()
  "Prune the on-disk equation cache of entries untouched for too long.

Deletes every cached SVG (with its `.eld' / `.log' siblings) whose
modification time is older than `latex-to-svg-backend-cache-max-age' days.
The SVG mtime is a last-use hint, bumped whenever an equation is (re)loaded
\(see `latex-to-svg-backend--touch'), so equations you keep viewing are kept;
a pruned one simply recompiles the next time it is needed.  An entry with
no SVG, left by a failed compile, is dated by its `.eld' failure record,
else by its `.log' (see `latex-to-svg-backend--entry-lead'); a pruned one
is compiled again the next time it is needed.

Runs automatically about once a day (see `latex-to-svg-backend-gc-interval');
this command forces a run now.  Returns a cons (DELETED . BYTES-FREED)."
  (interactive)
  (let* ((svg-dir (expand-file-name "svg" (latex-to-svg-backend--cache-dir)))
         (files (and (file-directory-p svg-dir)
                     (directory-files-recursively
                      svg-dir "\\.\\(?:svg\\|eld\\|log\\)\\'")))
         (now (float-time))
         (max-age (and latex-to-svg-backend-cache-max-age
                       (* latex-to-svg-backend-cache-max-age 86400)))
         (deleted 0) (freed 0))
    (when max-age
      (dolist (f files)
        ;; Each entry once, through the file that dates it.
        (when (equal f (latex-to-svg-backend--entry-lead f))
          (let ((mtime (float-time (file-attribute-modification-time
                                    (file-attributes f)))))
            (when (> (- now mtime) max-age)
              (cl-incf freed (latex-to-svg-backend--delete-entry f))
              (cl-incf deleted))))))
    (latex-to-svg-backend--record-gc-time)
    (when (called-interactively-p 'interactive)
      (message "latex-to-svg-backend: GC removed %d equation(s), freed %s"
               deleted (file-size-human-readable freed)))
    (cons deleted freed)))

;;;###autoload
(defun latex-to-svg-backend-clear-cache ()
  "Delete every cached equation SVG and its `.eld'/`.log' siblings.

Empties the on-disk equation cache (all shards) and the in-memory image
cache; precompiled `.fmt' format files are kept (see
`latex-to-svg-backend-flush-format').  Every equation simply recompiles on
next use — a blunt companion to `latex-to-svg-backend-gc' and
`latex-to-svg-backend-invalidate'."
  (interactive)
  (let ((svg-dir (expand-file-name "svg" (latex-to-svg-backend--cache-dir))))
    (when (file-directory-p svg-dir)
      (delete-directory svg-dir t)))
  (clrhash latex-to-svg-backend--image-cache))

(defvar latex-to-svg-backend--gc-timer nil
  "Idle timer that periodically triggers `latex-to-svg-backend--maybe-gc', or nil.")

(defun latex-to-svg-backend--maybe-gc ()
  "Run `latex-to-svg-backend-gc' unless a GC ran within the interval.
Idle-timer entry point.  Honours `latex-to-svg-backend-gc-interval' (nil
disables automatic GC) and enforces the cadence via the on-disk timestamp,
so the cache is collected at most once per interval across every session
that shares it — including a daemon left running for days."
  (when (and latex-to-svg-backend-gc-interval
             (> (- (float-time) (latex-to-svg-backend--last-gc-time))
                (* latex-to-svg-backend-gc-interval 86400)))
    (latex-to-svg-backend-gc)))

;; Install the periodic GC.  The short idle period only decides how soon
;; after going idle the cadence check runs; the real frequency is bounded by
;; `latex-to-svg-backend-gc-interval' via the on-disk timestamp.  Skipped in
;; batch (tests drive `latex-to-svg-backend-gc' directly).
(unless (or noninteractive latex-to-svg-backend--gc-timer)
  (setq latex-to-svg-backend--gc-timer
        (run-with-idle-timer 300 t #'latex-to-svg-backend--maybe-gc)))

(provide 'latex-to-svg-backend-core)

;;; latex-to-svg-backend-core.el ends here
