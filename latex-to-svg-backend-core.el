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
;; sizing, cache addressing, the display image, the
;; process chain, the compile outcome and the cache garbage collector.
;; The engines live in `latex-to-svg-backend-latex' and
;; `latex-to-svg-backend-ratex', the public entry point in
;; `latex-to-svg-backend'.  Load `latex-to-svg-backend', not this file.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'image)
(require 'seq)

(defgroup latex-to-svg-backend nil
  "Render LaTeX math to SVG images with `latex' + `dvisvgm' or with RaTeX.
Equations are compiled to a color- and size-independent SVG, cached
on disk by content, then tinted and scaled at display time to the
color and font size the caller passes."
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
  "Size of rendered equations relative to the text around them.

Equation images are scaled so the x-height of the equation's font, the
height of its lowercase `x', is the x-height of the font of the text
around it, which the front-end passes; this multiplier rides on top of
that match.  1.0 makes the equation's lowercase letters as tall as the
text's; greater than 1 enlarges, less than 1 shrinks.
Because the match is recomputed from the font on each render,
equations track it across themes, faces, and text scale."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg-backend)

(defcustom latex-to-svg-backend-render-on-non-graphic nil
  "Obsolete since 0.14.0, and without effect.
Rendering equations while no frame is graphical is no longer
supported: whether to render is the front-end's decision, since only
the front-end knows which frame shows the buffer, and the front-ends
compile nothing while every frame is a terminal frame.  A non-nil value
is reported once in each buffer that shows equations."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-backend)

(make-obsolete-variable
 'latex-to-svg-backend-render-on-non-graphic
 "rendering while no frame is graphical is no longer supported."
 "0.14.0")

(defcustom latex-to-svg-backend-svg-dpi 96.0
  "Obsolete since 0.14.0, and without effect.
Each image is now given its width in pixels, computed from the font
size the front-end passes, so the resolution at which Emacs converts
an SVG's pt to pixels no longer matters.  A value other than 96.0 is
reported once in each buffer that shows equations."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg-backend)

(make-obsolete-variable
 'latex-to-svg-backend-svg-dpi
 "equations are sized from the font size the front-end passes."
 "0.14.0")

;; Not `:safe': the queue is shared by every buffer, and a compile starts
;; from whichever sentinel frees a slot, so a buffer-local value would be
;; read in an unrelated buffer.
(defcustom latex-to-svg-backend-jobs nil
  "Maximum number of compiles to run at once.
nil uses the number of processors (`num-processors').  Further
compiles wait in a queue and start, oldest first, as running ones
end.  A compile holds its place from its first process to its last:
`latex' and `dvisvgm', or `render-svg'."
  :type '(choice (const :tag "Number of processors" nil)
                 (natnum :tag "Compiles"))
  :group 'latex-to-svg-backend)

;;;; State

;; image-cache key = content key (sha1 of latex + preamble + style) plus the
;; display size and tint color, via `latex-to-svg-backend--image-cache-key'.  Folding
;; size and color in lets images at different font sizes / themes coexist, so
;; a font or theme change just adds an entry (no cache clear) and sibling
;; buffers' warm images survive.  The underlying SVG is still compiled at most
;; once per content key (the disk cache is font- AND color-independent); only
;; the cheap `create-image' is per size/color.
(defvar latex-to-svg-backend--image-cache (make-hash-table :test 'equal)
  "In-memory map of image-cache key to rendered equation image.")

;; key -> list of waiters (see `latex-to-svg-backend--waiter') awaiting one
;; in-flight compile.  Dedupes concurrent compiles of the same equation and
;; records every consumer to notify once the SVG is ready, or to report to
;; when the compile fails.
(defvar latex-to-svg-backend--pending (make-hash-table :test 'equal)
  "In-memory map of cache key to waiters awaiting a queued or running compile.")

;; At most `latex-to-svg-backend-jobs' compiles run at once (see
;; `latex-to-svg-backend--schedule').  A compile holds its slot until
;; `latex-to-svg-backend--compile-done', across all its processes.
(defvar latex-to-svg-backend--queue nil
  "Compiles waiting for a slot, oldest first, as (KEY START ENGINE) lists.
START is a function of no arguments that starts the compile of KEY by
ENGINE.")

(defvar latex-to-svg-backend--running nil
  "Content keys of the compiles holding a slot.")

(defvar latex-to-svg-backend--processes (make-hash-table :test 'equal)
  "In-memory map of content key to the process of its compile running now.
`latex-to-svg-backend--run-process-chain' sets it as each stage starts
and removes it as the stage ends; `latex-to-svg-backend--stop' removes
it before it kills the process, which tells the chain the compile was
cancelled.")

(defvar latex-to-svg-backend--in-request nil
  "Non-nil while `latex-to-svg-backend' runs.
A request can end before it returns, as when a program is not found,
which fails as the compile starts.  `latex-to-svg-backend--call-back'
then calls the callback from a timer.")

(defun latex-to-svg-backend--waiter
    (callback &optional quiet fallback tentative)
  "Return a waiter for CALLBACK, requested from the current buffer.
A waiter is the plist (:callback CALLBACK :buffer BUFFER :quiet QUIET
:fallback FALLBACK :tentative TENTATIVE) queued in
`latex-to-svg-backend--pending'.  CALLBACK
is the caller's function of one argument, the outcome (see
`latex-to-svg-backend--call-back').  BUFFER is the requesting buffer,
which a failure is reported in.  QUIET non-nil reports no compile failure
for this request.  FALLBACK is nil or a function of one argument, the
waiter, that takes the request over to the fallback engine when the
compile fails because of the formula.  TENTATIVE non-nil says a failure
of this request is expected and is not recorded (see
`latex-to-svg-backend--tentative-p')."
  (list :callback callback :buffer (current-buffer)
        :quiet quiet :fallback fallback :tentative tentative))

(defun latex-to-svg-backend--tentative-p (key)
  "Return non-nil when every request waiting for KEY is tentative.
KEY is a content key with waiters in `latex-to-svg-backend--pending'
\(see `latex-to-svg-backend--waiter').  A failed compile of KEY is then
not recorded; one request that is not tentative has it recorded."
  (when-let* ((waiters (gethash key latex-to-svg-backend--pending)))
    (seq-every-p (lambda (waiter) (plist-get waiter :tentative)) waiters)))

;;;; Error reporting

;; A warning belongs to the buffer that requested the work: it is shown once
;; per buffer per cause, so equations within one buffer share one warning,
;; and opening the file again shows it again.  The marks live with the
;; buffer and die with it.
(defvar-local latex-to-svg-backend--warned nil
  "Causes already reported in this buffer (see `latex-to-svg-backend--warn').")

(defvar latex-to-svg-backend--orphaned nil
  "Non-nil while the backend works for a buffer that was killed.
`latex-to-svg-backend--warn' shows nothing then: nobody is looking at
the equation.  See `latex-to-svg-backend--with-requester'.")

(defun latex-to-svg-backend--warn (cause message)
  "Show MESSAGE as a warning naming the current buffer, once for CAUSE.
CAUSE is a string naming the problem; the current buffer is marked with
it, so a second request in the buffer with the same CAUSE shows nothing,
and another buffer shows it again.  MESSAGE names the cause and how to
fix it.  Return non-nil when the warning was shown.

The current buffer must be the one that requested the work.  Code run
from a process sentinel finds it in the waiters (see
`latex-to-svg-backend--warn-waiters'); code run for a killed buffer
shows nothing (see `latex-to-svg-backend--orphaned')."
  (unless (member cause latex-to-svg-backend--warned)
    (when (latex-to-svg-backend--warn-always message)
      (push cause latex-to-svg-backend--warned)
      t)))

(defun latex-to-svg-backend--warn-always (message)
  "Show MESSAGE as a warning naming the current buffer, and mark nothing.
For a warning that is to be shown each time its cause happens.  As for
`latex-to-svg-backend--warn', the current buffer must be the one that
requested the work, and code run for a killed buffer shows nothing.
Return non-nil when the warning was shown."
  (unless latex-to-svg-backend--orphaned
    (display-warning 'latex-to-svg-backend
                     (format "%s: %s" (buffer-name) message)
                     :warning)
    t))

(defun latex-to-svg-backend--warn-waiters (key cause message)
  "Warn with MESSAGE for CAUSE in each live buffer waiting for KEY.
KEY is a content key with waiters in `latex-to-svg-backend--pending'.
For code run from a process sentinel, where the current buffer is not
the one that requested the compile.  See `latex-to-svg-backend--warn'."
  (dolist (buffer (delete-dups
                   (mapcar (lambda (waiter) (plist-get waiter :buffer))
                           (gethash key latex-to-svg-backend--pending))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((latex-to-svg-backend--orphaned nil))
          (latex-to-svg-backend--warn cause message))))))

(defmacro latex-to-svg-backend--with-requester (buffer &rest body)
  "Run BODY in BUFFER, the buffer that requested it.
When BUFFER was killed, run BODY in the current buffer with no warnings
\(see `latex-to-svg-backend--orphaned')."
  (declare (indent 1) (debug t))
  (let ((b (make-symbol "buffer")))
    `(let ((,b ,buffer))
       (if (buffer-live-p ,b)
           (with-current-buffer ,b
             (let ((latex-to-svg-backend--orphaned nil))
               ,@body))
         (let ((latex-to-svg-backend--orphaned t))
           ,@body)))))

(defun latex-to-svg-backend--cache-fix ()
  "Return the sentence that says how to fix an unwritable cache directory."
  (format "Make %s writable, or set `latex-to-svg-backend-cache-directory' \
to another directory."
          (latex-to-svg-backend--cache-dir-name)))

;;;; Colors

(defun latex-to-svg-backend--hex-color (color argument)
  "Return COLOR, a `#rrggbb' string or nil; signal an error otherwise.
ARGUMENT names the keyword in the error message.  The backend resolves
no color names: a name resolves on a frame, and the backend does not
know which frame shows the buffer.  The caller resolves it there."
  (unless (or (null color)
              (and (stringp color)
                   (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color)))
    (error "Invalid %s %S: want a `#rrggbb' string" argument color))
  color)

;;;; Capability

(defun latex-to-svg-backend-available-p ()
  "Return non-nil when this Emacs can display SVG images.
The backend builds every image with `create-image' of type `svg', which
needs an Emacs built with librsvg.  This depends on the build, not on a
frame: whether to request a render, for a buffer shown only on a
terminal say, is the front-end's decision."
  (image-type-available-p 'svg))

(defconst latex-to-svg-backend--no-svg-message
  "This Emacs cannot display SVG images: it was built without librsvg."
  "What the warning and the failure say when SVG images cannot be shown.")

(defun latex-to-svg-backend--report-no-svg ()
  "Warn that this Emacs cannot display SVG images, and return nil.
Once per buffer (see `latex-to-svg-backend--warn'), even for a quiet
request: it is a configuration problem, not the formula's."
  (latex-to-svg-backend--warn
   "no SVG support"
   (concat latex-to-svg-backend--no-svg-message
           "\nEquations stay as LaTeX source.  To see them, use an Emacs \
built with librsvg."))
  nil)

(defun latex-to-svg-backend--report-obsolete-options ()
  "Warn that an obsolete option without effect is set.
Once per buffer and option (see `latex-to-svg-backend--warn'): the
options are read on every request."
  (when (with-suppressed-warnings
            ((obsolete latex-to-svg-backend-svg-dpi))
          (not (eql latex-to-svg-backend-svg-dpi 96.0)))
    (latex-to-svg-backend--warn
     "obsolete option/svg-dpi"
     "`latex-to-svg-backend-svg-dpi' is obsolete since 0.14.0 and has no \
effect: equations are sized from the font size the front-end passes.
To change their size, set `latex-to-svg-backend-font-scale'."))
  (when (with-suppressed-warnings
            ((obsolete latex-to-svg-backend-render-on-non-graphic))
          latex-to-svg-backend-render-on-non-graphic)
    (latex-to-svg-backend--warn
     "obsolete option/render-on-non-graphic"
     "`latex-to-svg-backend-render-on-non-graphic' is obsolete since 0.14.0 \
and has no effect: rendering while no frame is graphical is no longer \
supported.
If your workflow needs it, please open an issue at \
https://github.com/alberti42/latex-to-svg-backend/issues describing \
that workflow.")))

;;;; Cache addressing

(defun latex-to-svg-backend--cache-dir ()
  "Return the root cache directory, creating it if needed.
Honours `latex-to-svg-backend-cache-directory', else `$XDG_CACHE_HOME'
\(or `~/.cache') under `emacs/latex-to-svg/'.  Files are organised into
`svg/' (sharded equation SVGs + sidecars), `fmt/' (precompiled
preambles) and `tmp/' (the scratch directories of compiles, see
`latex-to-svg-backend--scratch-dir') subdirectories, plus the
`gc-timestamp' housekeeping file."
  (let ((dir (latex-to-svg-backend--cache-dir-name)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun latex-to-svg-backend--cache-dir-name ()
  "Return the name of the root cache directory, without creating it.
See `latex-to-svg-backend--cache-dir'."
  (or latex-to-svg-backend-cache-directory
      (expand-file-name
       "emacs/latex-to-svg/"
       (or (getenv "XDG_CACHE_HOME")
           (expand-file-name "~/.cache")))))

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

(defun latex-to-svg-backend--scratch-dir ()
  "Create and return a new scratch directory for one compile.
It is under the `tmp/' subdirectory of the cache directory, so an SVG
written there reaches the cache by a rename (see
`latex-to-svg-backend--move-to-cache').  The compile deletes it when it
ends; one left by a crash is deleted by `latex-to-svg-backend-gc'."
  (make-temp-file (expand-file-name "compile-"
                                    (latex-to-svg-backend--subdir "tmp"))
                  t))

(defun latex-to-svg-backend--move-to-cache (file svg)
  "Move FILE, an SVG in a scratch directory, to the cache file SVG.
Both are under the cache directory, so this is a rename, and a request
finds either no SVG or the whole of it.  Return t."
  (rename-file file svg t)
  t)

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
time, so this is called whenever a cached SVG is (re)loaded.  A `.fmt'
file has its own (see `latex-to-svg-backend--touch-format').

Signals `file-missing' when FILE is gone -- the caller treats that as a
cache miss (see `latex-to-svg-backend--cached-image').  Any other refusal
by the filesystem is reported once per buffer (see
`latex-to-svg-backend--warn') and then tolerated: the mtime only orders
GC, so an entry owned by another user (a cache populated once under
sudo) or on a read-only mount is left untouched, ages out, and
recompiles."
  (condition-case err
      (set-file-times file)
    ;; A collected entry belongs to the caller, which turns it into a miss.
    (file-missing (signal (car err) (cdr err)))
    (file-error
     (latex-to-svg-backend--warn
      "recording cache use"
      (format "Cannot record the use of %s: %s.
The garbage collector deletes an equation unused for \
`latex-to-svg-backend-cache-max-age' days, and cannot tell that this \
one is in use.  %s"
              file (error-message-string err)
              (latex-to-svg-backend--cache-fix))))))

;;;; SVG markup

(defun latex-to-svg-backend--svg-root (svg)
  "Return the bounds of SVG's root start tag, as (BEG . END), or nil."
  (when (string-match "<svg\\b[^>]*>" svg)
    (cons (match-beginning 0) (match-end 0))))

(defun latex-to-svg-backend--svg-attribute-regexp (name)
  "Return a regexp matching attribute NAME in an SVG start tag.
Group 1 is a double-quoted value, group 2 a single-quoted one: svg.el,
RaTeX and pdftocairo write the first, dvisvgm and
`latex-to-svg-backend--crop-to-ink' the second."
  (concat "[[:space:]]" (regexp-quote name)
          "=\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\)"))

(defun latex-to-svg-backend--svg-attribute (tag name)
  "Return the value of attribute NAME in the SVG start TAG, or nil."
  (when (string-match (latex-to-svg-backend--svg-attribute-regexp name) tag)
    (or (match-string 1 tag) (match-string 2 tag))))

(defun latex-to-svg-backend--svg-set-attribute (tag name value)
  "Return the SVG start TAG with attribute NAME set to VALUE.
The quotes are kept.  TAG is returned unchanged when it has no NAME."
  (if (string-match (latex-to-svg-backend--svg-attribute-regexp name) tag)
      (replace-match value t t tag (if (match-beginning 1) 1 2))
    tag))

;;;; Baseline

(defconst latex-to-svg-backend--baseline-comment
  "<!--latex-to-svg-backend-baseline %s-->"
  "Format of the comment that gives an SVG's baseline.
Its argument is the y coordinate of the baseline of the equation's
line, in the coordinates of the SVG's `viewBox'.  Each engine writes it
for inline math: the LaTeX engine through a dvisvgm special (see
`latex-to-svg-backend--latex-baseline-mark'), texres and RaTeX in their
store step.  A display equation has none, and is centred on its line.")

(defun latex-to-svg-backend--svg-baseline (svg)
  "Return the y coordinate of SVG's baseline, or nil when it has none.
See `latex-to-svg-backend--baseline-comment'."
  (when (string-match "<!--latex-to-svg-backend-baseline \\(-?[0-9.]+\\)-->"
                      svg)
    (string-to-number (match-string 1 svg))))

(defun latex-to-svg-backend--mark-svg (svg comment value)
  "Return SVG with COMMENT, formatted with VALUE, after the root tag.
SVG is returned unchanged when VALUE is nil or SVG has no root element."
  (if-let* ((value)
            (root (latex-to-svg-backend--svg-root svg)))
      (concat (substring svg 0 (cdr root))
              (format comment (format "%.6f" value))
              (substring svg (cdr root)))
    svg))

(defun latex-to-svg-backend--mark-baseline (svg y)
  "Return SVG with the comment giving its baseline Y after the root tag.
See `latex-to-svg-backend--baseline-comment'.  SVG is returned unchanged
when Y is nil or SVG has no root element."
  (latex-to-svg-backend--mark-svg
   svg latex-to-svg-backend--baseline-comment y))

;;;; X-height

(defconst latex-to-svg-backend--x-height-comment
  "<!--latex-to-svg-backend-x-height %s-->"
  "Format of the comment that gives the x-height of an SVG's font.
Its argument is the x-height of the font the equation is set in, in
the SVG's units: the LaTeX engines write `\\fontdimen5' of the math
italic font (see `latex-to-svg-backend--latex-x-height-mark'), so a
preamble that loads another math font is followed; RaTeX writes its
font's (see `latex-to-svg-backend--ratex-x-height').  Every cache SVG
has it, display equations too.")

(defun latex-to-svg-backend--svg-x-height (svg)
  "Return the x-height SVG gives for its font, in its units, or nil.
See `latex-to-svg-backend--x-height-comment'.  The value may carry a
`pt' unit, as TeX writes it."
  (when (string-match
         "<!--latex-to-svg-backend-x-height \\([0-9.]+\\)\\(?:pt\\)?-->" svg)
    (let ((value (string-to-number (match-string 1 svg))))
      (and (> value 0) value))))

(defun latex-to-svg-backend--mark-x-height (svg x-height)
  "Return SVG with the comment giving its font's X-HEIGHT after the root tag.
See `latex-to-svg-backend--x-height-comment'."
  (latex-to-svg-backend--mark-svg
   svg latex-to-svg-backend--x-height-comment x-height))

(defun latex-to-svg-backend--svg-geometry (svg)
  "Return SVG's root geometry as (WIDTH HEIGHT X Y W H), or nil.
WIDTH and HEIGHT are the root's `width' and `height' in pt; X, Y, W
and H its `viewBox'.  Nil when one of them is missing, or WIDTH or
HEIGHT is not in pt."
  (when-let* ((root (latex-to-svg-backend--svg-root svg))
              (tag (substring svg (car root) (cdr root)))
              (number "\\`-?[0-9.eE+-]+\\'")
              (pt (lambda (name)
                    (when-let* ((value (latex-to-svg-backend--svg-attribute
                                        tag name))
                                ((string-suffix-p "pt" value))
                                ((string-match-p
                                  number (substring value 0 -2))))
                      (string-to-number value))))
              (width (funcall pt "width"))
              (height (funcall pt "height"))
              (view-box (split-string
                         (or (latex-to-svg-backend--svg-attribute tag "viewBox")
                             "")
                         "[ ,]+" t))
              ((= (length view-box) 4))
              ((seq-every-p (lambda (v) (string-match-p number v)) view-box)))
    (cons width (cons height (mapcar #'string-to-number view-box)))))

(defun latex-to-svg-backend--ascent (svg)
  "Return the `:ascent' that puts SVG's baseline on the line's baseline.
That is the share of the image above the baseline, in percent (see
`latex-to-svg-backend--svg-baseline'), rounded and kept within 0..100.
`center' when SVG gives no baseline, as for a display equation.

The baseline is the one TeX (or RaTeX) set the equation's line on, as
the `org-latex-preview' package of Org's development branch uses it to
align previews; there the height and the depth come from the
`preview' package, here the position comes from the shipped page, and
the image is cropped to its ink."
  (if-let* ((y (latex-to-svg-backend--svg-baseline svg))
            (geometry (latex-to-svg-backend--svg-geometry svg))
            (top (nth 3 geometry))
            (height (nth 5 geometry))
            ((> height 0)))
      (max 0 (min 100 (round (* 100 (/ (- y top) height)))))
    'center))

;;;; Scale

(defun latex-to-svg-backend--target-x-height (x-height &optional rescale-by)
  "Return the x-height in pixels an equation is displayed at, or nil.
X-HEIGHT is the x-height of the font of the text around the equation,
in pixels, the height of its lowercase `x'.  The equation's font is
displayed with that x-height times `latex-to-svg-backend-font-scale'
and RESCALE-BY (default 1.0), a front-end's per-call multiplier, so at
1.0 the equation's lowercase letters have the height of the text's,
as CSS's `font-size-adjust' matches two fonts.  Nil when X-HEIGHT is
nil: the buffer is shown nowhere, and the caller builds the image once
it is shown -- the on-disk SVG is size-independent, so it can be
compiled now and sized later with no recompile.

Computed, not measured: an image is given its width in pixels (see
`latex-to-svg-backend--load-svg-image'), so neither the resolution at
which Emacs converts an SVG's pt to pixels, which differs between
ports, nor `image-size' enters the size."
  (when x-height
    (* x-height latex-to-svg-backend-font-scale (or rescale-by 1.0))))

(defun latex-to-svg-backend-image-width (image)
  "Return the width in pixels at which IMAGE is displayed, or nil.
IMAGE is an image this backend returned: it has an explicit `:width'
in pixels at `:scale' 1.0 (see `latex-to-svg-backend--load-svg-image'),
which is its displayed width.  Nil when IMAGE is not an image or has
no `:width'."
  (when (eq (car-safe image) 'image)
    (image-property image :width)))

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
            (root (latex-to-svg-backend--svg-root data))
            (tag (substring data (car root) (cdr root)))
            (geometry (latex-to-svg-backend--svg-geometry data)))
      (pcase-let* ((`(,top ,right ,bottom ,left) box)
                   (`(,w ,h ,vx ,vy ,vw ,vh) geometry)
                   (nx (- vx left)) (ny (- vy top))
                   (nw (+ vw left right)) (nh (+ vh top bottom))
                   (new-tag tag)
                   (rect (if background
                             (format "<rect x='%s' y='%s' width='%s' height='%s' fill='%s'/>"
                                     nx ny nw nh background)
                           "")))
        (setq new-tag (latex-to-svg-backend--svg-set-attribute
                       new-tag "width" (format "%spt" (+ w left right)))
              new-tag (latex-to-svg-backend--svg-set-attribute
                       new-tag "height" (format "%spt" (+ h top bottom)))
              new-tag (latex-to-svg-backend--svg-set-attribute
                       new-tag "viewBox" (format "%s %s %s %s" nx ny nw nh)))
        (concat (substring data 0 (car root)) new-tag rect
                (substring data (cdr root))))
    data))

(defun latex-to-svg-backend--load-svg-image (file x-height &optional color background padding)
  "Return an SVG image from FILE, tinted COLOR, its font's x-height X-HEIGHT.
The on-disk SVG emits its default ink as the literal token
`currentColor' (dvisvgm `--currentcolor'); when COLOR (a `#rrggbb'
string) is given it is substituted in, so the equation takes that
color without recompiling.  The image has `:width' the SVG's width
times X-HEIGHT, in pixels (see `latex-to-svg-backend--target-x-height'),
over the x-height the SVG gives for its font (see
`latex-to-svg-backend--svg-x-height'), rounded, at `:scale' 1.0:
`create-image' applies `image-scaling-factor' only when `:scale' is not
given.  Its `:ascent' puts the equation's
baseline on the line's (see `latex-to-svg-backend--ascent').

The SVG is transparent; BACKGROUND, when non-nil (a `#rrggbb' string),
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
           :scale 1.0
           :width (max 1 (round (/ (* (or (car (latex-to-svg-backend--svg-geometry
                                                    data))
                                               (error "No width in pt in %s" file))
                                           x-height)
                                        (or (latex-to-svg-backend--svg-x-height data)
                                            (error "No x-height in %s" file)))))
           :ascent (latex-to-svg-backend--ascent data)
           ;; With padding the box is a baked-in <rect>; otherwise let
           ;; `create-image' composite the background behind the SVG.
           (and background (not pad) (list :background background)))))

(defun latex-to-svg-backend--image-cache-key (key x-height color &optional background padding)
  "Return the image-cache key for KEY at X-HEIGHT, COLOR, BACKGROUND, PADDING.
PADDING should be normalized (`latex-to-svg-backend--pad-box') before it
is keyed on, so that 6 and (6 6 6 6) name one entry rather than two.
KEY names the font- and color-independent on-disk SVG; the cached
image object bakes in a display size, X-HEIGHT, a tint COLOR, an optional
BACKGROUND box, and its PADDING, so the in-memory key adds all four.
Images at different font sizes, tints, box colors, or paddings coexist,
so any such change just creates a new entry — no cache clearing, and a
sibling buffer's warm images survive."
  (format "%s@%s@%s@%s@%s" key x-height color background padding))

(defun latex-to-svg-backend--cached-image (key &optional rescale-by color background padding x-height)
  "Return the rendered image for content KEY at X-HEIGHT and COLOR.
Checks the in-memory cache (keyed by KEY, the display size, the tint
color, the box background, and PADDING via
`latex-to-svg-backend--image-cache-key', so each variant has its own image),
else loads KEY's on-disk SVG and caches a freshly sized, tinted image.
X-HEIGHT (the x-height of the font of the text around the equation, in
pixels, measured by the caller) and RESCALE-BY (default 1.0) give the
display size (see `latex-to-svg-backend--target-x-height'), which feeds
the cache key, so
different sizes of the same equation coexist.  COLOR (a `#rrggbb'
string) is the tint.  BACKGROUND (a `#rrggbb' string) paints a box
behind the equation; nil keeps it transparent.  PADDING (pt) grows the
BACKGROUND box beyond the ink.  All apply at display time only -- same
on-disk SVG, no recompile -- and fold into the cache key so variants
coexist.  Returns nil when the SVG isn't on disk yet (its compile
hasn't finished) or X-HEIGHT is nil: the buffer is shown nowhere, so
the caller builds the image once it is shown."
  (when-let* ((target (latex-to-svg-backend--target-x-height x-height rescale-by)))
    (let* (;; Normalize the padding spec once: the cache key is built from it
           ;; too, and 6 and (6 6 6 6) are the same box -- they must not
           ;; occupy two entries.
           (padding (latex-to-svg-backend--pad-box padding))
           (image-key (latex-to-svg-backend--image-cache-key
                       key target color background padding)))
      (or (gethash image-key latex-to-svg-backend--image-cache)
          (let ((file (latex-to-svg-backend--svg-file key)))
            (when (file-exists-p file)
              ;; The cache is shared across sessions, so another session's GC
              ;; can collect the entry between the check above and the read
              ;; below.  That is a miss -- the caller recompiles, which is
              ;; what a cache is for -- so nothing is reported.
              (condition-case nil
                  (progn
                    ;; Record the access for the LRU garbage collector.
                    (latex-to-svg-backend--touch file)
                    (puthash image-key
                             (latex-to-svg-backend--load-svg-image
                              file target color background padding)
                             latex-to-svg-backend--image-cache))
                (file-missing nil))))))))

;;;; Crop to the ink

(defun latex-to-svg-backend--transform-point (matrix x y)
  "Return the point X Y mapped through MATRIX, as (X Y).
MATRIX is (A B C D E F), the arguments of an SVG `matrix()' transform,
or nil for none."
  (if matrix
      (pcase-let ((`(,a ,b ,c ,d ,e ,f) matrix))
        (list (+ (* a x) (* c y) e) (+ (* b x) (* d y) f)))
    (list x y)))

(defun latex-to-svg-backend--elements-box (svg &optional glyphs)
  "Return the box around the elements drawn in SVG, as (X0 Y0 X1 Y1), or nil.
SVG is markup without `<defs>'.  GLYPHS is an alist of (ID . BOX) for
the `<use>' elements to place (see `latex-to-svg-backend--ink-box').

A path's box is taken over its control points, which bound the curve;
its coordinates must be absolute pairs (M, L, Q, C and Z commands).  A
`transform' attribute must be a `matrix()'.  A stroked element's box
grows by half its `stroke-width', scaled by the transform."
  (let ((start 0) box)
    (while (string-match "<\\(path\\|rect\\|line\\|use\\)[[:space:]][^>]*>"
                         svg start)
      (let ((tag (match-string 0 svg))
            (kind (match-string 1 svg)))
        (setq start (match-end 0))
        (let* ((attr (lambda (name)
                       (latex-to-svg-backend--svg-attribute tag name)))
               (num (lambda (name)
                      (string-to-number (or (funcall attr name) "0"))))
               (matrix
                (when-let* ((transform (funcall attr "transform"))
                            ((string-match "\\`matrix(\\([^)]*\\))\\'" transform)))
                  (mapcar #'string-to-number
                          (split-string (match-string 1 transform) "[ ,]+" t))))
               (stroke (funcall attr "stroke"))
               (grow (if (and stroke (not (equal stroke "none")))
                         (* (/ (funcall num "stroke-width") 2.0)
                            (if matrix
                                (pcase-let ((`(,a ,b ,c ,d) matrix))
                                  (sqrt (abs (- (* a d) (* b c)))))
                              1))
                       0))
               (points
                (pcase kind
                  ("path"
                   (seq-partition
                    (mapcar #'string-to-number
                            (split-string (or (funcall attr "d") "")
                                          "[^-0-9.eE]+" t))
                    2))
                  ("rect"
                   (let ((x (funcall num "x")) (y (funcall num "y")))
                     (list (list x y)
                           (list (+ x (funcall num "width"))
                                 (+ y (funcall num "height"))))))
                  ("line"
                   (list (list (funcall num "x1") (funcall num "y1"))
                         (list (funcall num "x2") (funcall num "y2"))))
                  ("use"
                   (when-let* ((href (or (funcall attr "xlink:href")
                                         (funcall attr "href")))
                               (glyph (cdr (assoc (if (string-prefix-p "#" href)
                                                      (substring href 1)
                                                    href)
                                                  glyphs))))
                     (pcase-let ((`(,x0 ,y0 ,x1 ,y1) glyph)
                                 (x (funcall num "x"))
                                 (y (funcall num "y")))
                       ;; All four corners, so a transform maps the box.
                       (list (list (+ x x0) (+ y y0)) (list (+ x x1) (+ y y0))
                             (list (+ x x0) (+ y y1)) (list (+ x x1) (+ y y1)))))))))
          (pcase-dolist (`(,px ,py) points)
            (when py
              (pcase-let ((`(,x ,y) (latex-to-svg-backend--transform-point
                                     matrix px py)))
                (setq box
                      (if box
                          (pcase-let ((`(,x0 ,y0 ,x1 ,y1) box))
                            (list (min x0 (- x grow)) (min y0 (- y grow))
                                  (max x1 (+ x grow)) (max y1 (+ y grow))))
                        (list (- x grow) (- y grow) (+ x grow) (+ y grow))))))))))
    box))

(defun latex-to-svg-backend--ink-box (svg)
  "Return the box around the ink of SVG, as (X0 Y0 X1 Y1), or nil.
dvisvgm's `--exact-bbox' crops the LaTeX engine's SVGs to their ink;
this is the same box for an engine whose SVG is sized otherwise.

The ink is drawn with `<path>', `<rect>' and `<line>' elements (see
`latex-to-svg-backend--elements-box'), and with `<use>' elements that
place a group of `<defs>', as pdftocairo draws each glyph: such a group
counts only where a `<use>' places it.  Nil when SVG has no ink."
  (let ((glyphs nil)
        (body svg))
    (when (string-match "<defs>\\(\\(?:.\\|\n\\)*?\\)</defs>" svg)
      (let ((defs (match-string 1 svg))
            (start 0))
        (setq body (replace-match "" t t svg))
        (while (string-match
                "<g id=\"\\([^\"]+\\)\"[^>]*>\\(\\(?:.\\|\n\\)*?\\)</g>"
                defs start)
          (setq start (match-end 0))
          (let ((id (match-string 1 defs)))
            (when-let* ((box (latex-to-svg-backend--elements-box
                              (match-string 2 defs))))
              (push (cons id box) glyphs))))))
    (latex-to-svg-backend--elements-box body glyphs)))

(defun latex-to-svg-backend--crop-to-ink (svg ink)
  "Return SVG made color-independent and cropped to its ink, or nil.
INK is a regexp matching how SVG writes the color its engine drew the
default ink in; it becomes `currentColor', as dvisvgm's `--currentcolor'
does for the LaTeX engine.  The root element is rewritten with the
viewport around the ink (see `latex-to-svg-backend--ink-box') and in
the form dvisvgm writes it -- width and height in pt, values in single
quotes.  `latex-to-svg-backend--pad-svg' pads only a width and height in
pt.  One
SVG unit is one pt, as in the LaTeX engine's SVGs.  Nil when SVG has
no root element."
  (when-let* ((root (latex-to-svg-backend--svg-root svg)))
    (let* ((root-beg (car root))
           (root-end (cdr root))
           (view-box (latex-to-svg-backend--svg-attribute
                      (substring svg root-beg root-end) "viewBox"))
           (box (or (latex-to-svg-backend--ink-box svg)
                    ;; Nothing drawn (`\,' alone, say): keep the viewport.
                    (pcase-let ((`(,x ,y ,w ,h)
                                 (mapcar #'string-to-number
                                         (split-string (or view-box "0 0 0 0")))))
                      (list x y (+ x w) (+ y h))))))
      (pcase-let ((`(,x0 ,y0 ,x1 ,y1) box))
        (concat (substring svg 0 root-beg)
                (format "<svg xmlns='http://www.w3.org/2000/svg'%s \
width='%.4fpt' height='%.4fpt' viewBox='%.4f %.4f %.4f %.4f'>"
                        ;; `<use xlink:href=...>', as pdftocairo writes it.
                        (if (string-search "xlink:" svg)
                            " xmlns:xlink='http://www.w3.org/1999/xlink'"
                          "")
                        (- x1 x0) (- y1 y0) x0 y0 (- x1 x0) (- y1 y0))
                (replace-regexp-in-string
                 ink "currentColor" (substring svg root-end) t t))))))

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
    (stage command dir output-buffer sentinel &optional environment)
  "Start STAGE directly with argv COMMAND in DIR.
Send stdout and stderr to OUTPUT-BUFFER and install SENTINEL.  No
shell is involved, so this is independent of `shell-file-name'.
ENVIRONMENT is a list of \"VARIABLE=VALUE\" strings set for this
process only."
  (latex-to-svg-backend--append-process-log
   output-buffer (format "[%s] %S" stage command))
  (let ((default-directory (file-name-as-directory dir))
        (process-environment (append environment process-environment)))
    (make-process
     :name (format "latex-to-svg-backend-%s" stage)
     :buffer output-buffer
     :command command
     :connection-type 'pipe
     :noquery t
     :sentinel sentinel)))

(defun latex-to-svg-backend--run-process-chain
    (key dir output-buffer stages done)
  "Run STAGES sequentially in DIR, logging to OUTPUT-BUFFER, then call DONE.
KEY is the content key of the compile: the process of the stage that
runs is in `latex-to-svg-backend--processes' under KEY.
Each element of STAGES is (NAME COMMAND OUTPUT-FILE ENVIRONMENT), where
COMMAND is an argv list passed directly to `make-process' and the
optional ENVIRONMENT is as for `latex-to-svg-backend--start-process'.
Each stage's
terminal status, exit status, and sentinel event are logged to
OUTPUT-BUFFER.  A stage succeeds only when it exits with status zero
and OUTPUT-FILE exists.  DONE is called once with non-nil on complete
success and nil on any failed exit, signal, missing output, or process
startup error.  On a failed exit DONE gets a second argument, the cons
\(STAGE . EXIT-STATUS): the program ran and reported the failure itself,
which an engine reads to tell a formula it rejects from a crash.  When
the program of STAGE is not found, the second argument is
\(STAGE . PROGRAM), PROGRAM the string that names it (see
`latex-to-svg-backend--compile-failed').  `make-process' signals
`file-missing' for a name it does not find on the variable `exec-path',
but starts an absolute file name that does not exist, which exits with
status 127; only then is the file checked.

A stage whose process is no longer under KEY was cancelled (see
`latex-to-svg-backend--stop'): the chain then kills OUTPUT-BUFFER,
deletes DIR and does not call DONE."
  (cl-labels
      ((run
        (remaining)
        (if (null remaining)
            (funcall done t)
          (pcase-let* ((`(,stage ,command ,output-file ,environment)
                        (car remaining))
                       (settled nil))
            (condition-case err
                (puthash
                 key
                 (latex-to-svg-backend--start-process
                  stage command dir output-buffer
                  (lambda (process event)
                    (let ((status (process-status process)))
                      (when (and (not settled)
                                 (memq status '(exit signal)))
                        (setq settled t)
                        (if (not (eq (gethash key latex-to-svg-backend--processes)
                                     process))
                            ;; Cancelled: nobody waits for the outcome.
                            (progn
                              (when (buffer-live-p output-buffer)
                                (kill-buffer output-buffer))
                              (delete-directory dir t))
                          (remhash key latex-to-svg-backend--processes)
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
                                   (= exit-status 127)
                                   (file-name-absolute-p (car command))
                                   (not (file-executable-p (car command))))
                              (latex-to-svg-backend--append-process-log
                               output-buffer
                               (format "[%s] program not found: %s"
                                       stage (car command)))
                              (funcall done nil (cons stage (car command))))
                             ((and (eq status 'exit)
                                   (not (zerop exit-status)))
                              (funcall done nil (cons stage exit-status)))
                             (t (funcall done nil))))))))
                  environment)
                 latex-to-svg-backend--processes)
              (file-missing
               (latex-to-svg-backend--append-process-log
                output-buffer
                (format "[%s] failed to start: %s"
                        stage (error-message-string err)))
               (funcall done nil (cons stage (car command))))
              (error
               (latex-to-svg-backend--append-process-log
                output-buffer
                (format "[%s] failed to start: %s"
                        stage (error-message-string err)))
               (funcall done nil)))))))
    (run stages)))

;;;; Compile slots

(defun latex-to-svg-backend--jobs ()
  "Return how many compiles may run at once (see `latex-to-svg-backend-jobs')."
  (max 1 (or latex-to-svg-backend-jobs (num-processors))))

(defun latex-to-svg-backend--schedule (key start &optional engine)
  "Start the compile of KEY by ENGINE by calling START once a slot is free.
START is a function of no arguments.  Compiles start in the order they
were scheduled.  ENGINE is as for `latex-to-svg-backend--failure'."
  (setq latex-to-svg-backend--queue
        (nconc latex-to-svg-backend--queue (list (list key start engine))))
  (latex-to-svg-backend--fill-slots))

(defun latex-to-svg-backend--fill-slots ()
  "Start queued compiles while a slot is free."
  (while (and latex-to-svg-backend--queue
              (< (length latex-to-svg-backend--running)
                 (latex-to-svg-backend--jobs)))
    (pcase-let ((`(,key ,start ,engine) (pop latex-to-svg-backend--queue)))
      (push key latex-to-svg-backend--running)
      (latex-to-svg-backend--start-compile key start engine))))

(defun latex-to-svg-backend--start-compile (key start &optional engine)
  "Call START, which starts the compile of KEY in the slot KEY holds.
A compile that cannot start (its scratch directory cannot be created,
say) is reported in the buffers waiting for it and ended (see
`latex-to-svg-backend--compile-done'), so its slot is freed and the next
request for KEY compiles again.  Its waiters get a `setup' failure of
ENGINE (see `latex-to-svg-backend--failure').  It is reported, not
signaled: START often runs from the sentinel of the compile that freed
the slot."
  (condition-case err
      (funcall start)
    (error
     (let* ((message (format "The %s engine could not start a compile: %s"
                             (latex-to-svg-backend--engine-name engine)
                             (error-message-string err)))
            (failure (latex-to-svg-backend--failure
                      'setup engine :message message)))
       (latex-to-svg-backend--warn-waiters
        key "starting a compile"
        (format "%s.\n%s" message (latex-to-svg-backend--cache-fix)))
       (dolist (waiter (gethash key latex-to-svg-backend--pending))
         (latex-to-svg-backend--call-back (plist-get waiter :callback) failure)))
     (latex-to-svg-backend--compile-done key))))

;;;; Compile outcome

(defun latex-to-svg-backend--engine-name (engine)
  "Return the name of ENGINE (`latex', nil, `ratex' or `texres') for a message."
  (pcase-exhaustive engine
    ((or 'nil 'latex) "LaTeX")
    ('ratex "RaTeX")
    ('texres "texres")))

(defun latex-to-svg-backend--call-back (callback outcome)
  "Call CALLBACK with OUTCOME, which ends the request CALLBACK was given to.
OUTCOME is nil when the SVG is in the cache, and the request is to be
made again; otherwise it is the plist of `latex-to-svg-backend--failure'.
Nothing happens when CALLBACK is nil.  A callback that signals is
reported and does not keep the others from running.

While `latex-to-svg-backend' runs (`latex-to-svg-backend--in-request'),
CALLBACK is called from a timer, so it never runs before the request
returns."
  (when callback
    (if latex-to-svg-backend--in-request
        (run-at-time 0 nil #'latex-to-svg-backend--call-back callback outcome)
      (condition-case cb-err
          (funcall callback outcome)
        (error
         (message "latex-to-svg-backend: callback error: %S" cb-err))))))

(defun latex-to-svg-backend--notify-pending (key)
  "Call every callback queued for KEY (see `latex-to-svg-backend--enqueue').
Called once KEY's SVG is in the cache, so the outcome is nil (see
`latex-to-svg-backend--call-back')."
  (dolist (waiter (gethash key latex-to-svg-backend--pending))
    (latex-to-svg-backend--call-back (plist-get waiter :callback) nil)))

(defun latex-to-svg-backend--compile-done (key)
  "End KEY's compile: forget its waiters and free its slot.
Called once the waiters were notified or the failure handled, so a
request for KEY from now on finds the SVG or compiles again.  The freed
slot starts the oldest queued compile."
  (remhash key latex-to-svg-backend--pending)
  (when (member key latex-to-svg-backend--running)
    (setq latex-to-svg-backend--running
          (delete key latex-to-svg-backend--running))
    (latex-to-svg-backend--fill-slots)))

(defun latex-to-svg-backend--stop (key)
  "Stop the compile of KEY, which no request waits for any more.
A queued compile is taken off the queue.  A running one has the process
of its stage killed, and the chain deletes its scratch directory (see
`latex-to-svg-backend--run-process-chain'); its slot starts the next
compile (see `latex-to-svg-backend--compile-done').  Nothing is
recorded, so the next request for KEY compiles again.

A compile that holds a slot but runs no process is in the sentinel that
ends it, or starts its next stage: it is left to end, with no waiter
to call."
  (setq latex-to-svg-backend--queue
        (seq-remove (lambda (job) (equal (car job) key))
                    latex-to-svg-backend--queue))
  (remhash key latex-to-svg-backend--pending)
  (when-let* ((process (gethash key latex-to-svg-backend--processes)))
    ;; First, as `delete-process' runs the sentinel, which finds the
    ;; process missing and does not end the compile.
    (remhash key latex-to-svg-backend--processes)
    (delete-process process)
    (latex-to-svg-backend--compile-done key)))

(defun latex-to-svg-backend--report-failure (key latex engine &optional message)
  "Warn that ENGINE could not compile LATEX, whose content key is KEY.
Once per equation per buffer, in the current buffer, the one that
requested it (see `latex-to-svg-backend--warn').  MESSAGE is the
failure's (see `latex-to-svg-backend--failure'), or nil.  The warning
links to KEY's saved log when there is one."
  (let ((log (latex-to-svg-backend--log-file key)))
    (when (latex-to-svg-backend--warn
           (concat "compile failed/" key)
           (format "%s compile failed for: %s%s\nSee log: %s"
                   (latex-to-svg-backend--engine-name engine)
                   (truncate-string-to-width latex 60 nil nil t)
                   (if message (concat "\n" message) "")
                   (if (file-exists-p log) log "(no log available)")))
      (when (and (file-exists-p log) (get-buffer "*Warnings*"))
        (with-current-buffer "*Warnings*"
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (save-excursion
              (when (search-backward log nil t)
                (make-text-button (point) (+ (point) (length log))
                                  'action (lambda (_) (find-file log))
                                  'help-echo "Open the compile log")))))))))

(defun latex-to-svg-backend--report-missing-program (engine program)
  "Warn that ENGINE could not run PROGRAM, because it is not found.
A missing program is a configuration problem, not the formula's, so
the warning is given even for a quiet request, once per buffer per
ENGINE and PROGRAM, in the current buffer (see
`latex-to-svg-backend--warn').  Only the warning is once: nothing is
recorded, so every request runs PROGRAM again, and an equation compiles
as soon as PROGRAM is installed."
  (let ((engine (or engine 'latex)))
    (latex-to-svg-backend--warn
     (format "program not found/%s/%s" engine program)
     (format "%s
Install it, or set where it is with \
M-x customize-group RET latex-to-svg-backend-%s."
             (latex-to-svg-backend--missing-program-message engine program)
             engine))))

(defun latex-to-svg-backend--missing-program-message (engine program)
  "Return the line that says ENGINE could not run PROGRAM.
It starts the warning of `latex-to-svg-backend--report-missing-program'
and is the message of the failure."
  (format "The %s engine could not run `%s': program not found."
          (latex-to-svg-backend--engine-name engine) program))

(defun latex-to-svg-backend--setup-message (engine exit)
  "Return the message of a failure of ENGINE that is not the formula's.
EXIT is as for `latex-to-svg-backend--compile-failed': (STAGE .
EXIT-STATUS) when a stage exited with a status other than 0, nil when
one was killed, or exited with no output, or the SVG could not be
stored."
  (if (numberp (cdr exit))
      (format "The %s engine failed: %s exited with status %d"
              (latex-to-svg-backend--engine-name engine) (car exit) (cdr exit))
    (format "The %s engine wrote no SVG"
            (latex-to-svg-backend--engine-name engine))))

(cl-defun latex-to-svg-backend--failure
    (kind engine &key message line column key log program)
  "Return the plist that describes a request that ended without a picture.
That is (:kind KIND :engine ENGINE :message MESSAGE :line LINE :column
COLUMN :log LOG :program PROGRAM).  KIND is `formula' when ENGINE
rejected the equation, which is recorded, and `setup' otherwise: a
missing program, a crash, no SVG support, a preamble that failed to
dump.  ENGINE is the engine that failed, nil meaning `latex'.  MESSAGE
is one line, for a tooltip.  LINE \(1-based) and COLUMN (0-based)
locate the error in the LaTeX string the caller passed, or are nil.
LOG is the log saved for the equation of KEY (see
`latex-to-svg-backend--log-file'), unless LOG is given, or nil when
there is none.  PROGRAM is the program that was not found, for a
`setup' failure."
  (list :kind kind
        :engine (or engine 'latex)
        :message message
        :line line
        :column column
        :log (let ((log (or log
                            (and key (latex-to-svg-backend--log-file key)))))
               (and log (file-exists-p log) log))
        :program program))

(defun latex-to-svg-backend--file-stamp (file)
  "Return (NAME . MTIME) for FILE, or nil when it does not exist.
NAME is FILE with the symbolic links of its last component followed
\(`file-chase-links'), and MTIME the modification time of the file it
names.  `file-attributes' follows the links of the directories, so
the pair describes the file itself: the `ls-R' that Debian links into
the tree, or the binary behind `/Library/TeX/texbin/latex'.  It costs
a fraction of `file-truename', which resolves every component in Lisp
and takes most of a millisecond for a TeX binary."
  (let ((name (file-chase-links file)))
    (when-let* ((mtime (file-attribute-modification-time
                        (file-attributes name))))
      (cons name mtime))))

(defun latex-to-svg-backend--file-unchanged-p (entry)
  "Return non-nil when ENTRY, a (FILE . MTIME) pair, still holds.
That is when FILE exists and its modification time is MTIME."
  (and (consp entry)
       (when-let* ((mtime (file-attribute-modification-time
                           (file-attributes (car entry)))))
         (time-equal-p mtime (cdr entry)))))

(defun latex-to-svg-backend--record-failure (key failure &optional stamp)
  "Record in KEY's `.eld' sidecar that the formula failed to compile.
FAILURE is the plist of `latex-to-svg-backend--failure'.  The record is
`(:failed t . FAILURE)' without `:log' and `:program', followed by
STAMP: the log is found from KEY when the record is read, and a
recorded failure is the formula's, so no program is missing.  STAMP is
the plist of (NAME . MTIME) pairs (see
`latex-to-svg-backend--file-stamp') of the engine's program and of the
files it was installed with, as `latex-to-svg-backend--format-stamp'
writes it for a `.fmt' file.  A request that finds the record does not
compile again (see `latex-to-svg-backend') while STAMP holds, so an
update of the engine compiles the equation again, and until
`latex-to-svg-backend-invalidate' deletes it.  Runs in the compile
sentinel, so a sidecar that cannot be written is reported in the
buffers waiting for KEY (see `latex-to-svg-backend--warn-waiters'), and
the equation is simply compiled again next time.

The file is written as UTF-8, for the reason
`latex-to-svg-backend--compile' gives: a message can quote a character
of the equation."
  (condition-case err
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file (latex-to-svg-backend--meta-file key)
          (let ((print-length nil)
                (print-level nil))
            (prin1 (append (list :failed t
                                 :kind (plist-get failure :kind)
                                 :engine (plist-get failure :engine)
                                 :message (plist-get failure :message)
                                 :line (plist-get failure :line)
                                 :column (plist-get failure :column))
                           stamp)
                   (current-buffer)))))
    (file-error
     (latex-to-svg-backend--warn-waiters
      key "recording a failed compile"
      (format "Cannot record the failed compile in %s: %s.
The equation is compiled again on every request.  %s"
              (latex-to-svg-backend--meta-file key) (error-message-string err)
              (latex-to-svg-backend--cache-fix))))))

(defun latex-to-svg-backend--compile-failed
    (key latex dir &optional process-output engine fault exit stamp)
  "Handle a failed compile of LATEX by ENGINE for KEY.
DIR is the scratch directory containing equation.log when LaTeX
created one.  PROCESS-OUTPUT is the captured stdout and stderr from
the engine's processes.  A persistent log containing the
available diagnostics is written to the cache directory.

FAULT non-nil says the engine rejected the formula itself, so
compiling it again would fail again.  It is the plist (:message MESSAGE
:line LINE :column COLUMN) the engine read from its output (see
`latex-to-svg-backend--failure').  The failure is recorded with
STAMP (see `latex-to-svg-backend--record-failure'), unless every
request waiting for KEY is tentative (see
`latex-to-svg-backend--tentative-p'), and each waiter with a fallback
\(see `latex-to-svg-backend--waiter') is handed to it.  A
missing program, a crash or a killed process is not the formula's
fault, so it is not recorded and the next request compiles again.

EXIT is the second argument the engine's DONE received from
`latex-to-svg-backend--run-process-chain'.  When it says a program was
not found, that is reported (see
`latex-to-svg-backend--report-missing-program') instead of the failure
of LATEX, and no waiter is handed to its fallback.

A missing program is reported in every requesting buffer, quiet or
not.  Every other waiter that is not quiet gets a warning in its
requesting buffer, linking to the log (see
`latex-to-svg-backend--report-failure').  A buffer killed before the
compile ended gets no warning, and its fallback runs with none (see
`latex-to-svg-backend--with-requester').

Every waiter that is not handed to its fallback, quiet or not, has its
callback called with the failure (see `latex-to-svg-backend--call-back'):
of kind `formula' with FAULT, of kind `setup' otherwise, with the
program that was not found, if any.

The log is copied byte-for-byte (`raw-text' in and out): a TeX log
echoing an unencodable Unicode character would otherwise make
`write-region' prompt for a coding system from a background compile."
  (let* ((log-src (expand-file-name "equation.log" dir))
         (log-dst (latex-to-svg-backend--log-file key))
         (have-tex-log (file-exists-p log-src))
         (have-output (not (string-empty-p (or process-output "")))))
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
    (let* ((missing (and (stringp (cdr exit)) (cdr exit)))
           (fault (and (not missing) fault))
           (outcome
            (cond
             (missing
              (latex-to-svg-backend--failure
               'setup engine
               :message (latex-to-svg-backend--missing-program-message
                         engine missing)
               :key key :program missing))
             (fault
              (apply #'latex-to-svg-backend--failure 'formula engine
                     :key key fault))
             (t
              (latex-to-svg-backend--failure
               'setup engine
               :message (latex-to-svg-backend--setup-message engine exit)
               :key key)))))
      (when (and fault (not (latex-to-svg-backend--tentative-p key)))
        (latex-to-svg-backend--record-failure key outcome stamp))
      (dolist (waiter (gethash key latex-to-svg-backend--pending))
        (let ((fallback (plist-get waiter :fallback))
              (buffer (plist-get waiter :buffer)))
          (cond
           ((and fault fallback)
            ;; The fallback's own waiter has none, so a failure there is
            ;; reported instead of falling back again.  Its callback is
            ;; called when the fallback ends.
            (condition-case fb-err
                (latex-to-svg-backend--with-requester buffer
                  (funcall fallback
                           (plist-put (copy-sequence waiter) :fallback nil)))
              (error
               (message "latex-to-svg-backend: fallback error: %S" fb-err)
               (latex-to-svg-backend--call-back
                (plist-get waiter :callback) outcome))))
           (t
            (when (buffer-live-p buffer)
              (latex-to-svg-backend--with-requester buffer
                (cond
                 (missing
                  (latex-to-svg-backend--report-missing-program engine missing))
                 ((not (plist-get waiter :quiet))
                  (latex-to-svg-backend--report-failure
                   key latex engine (plist-get outcome :message))))))
            (latex-to-svg-backend--call-back
             (plist-get waiter :callback) outcome))))))))

;;;; Cache maintenance (garbage collection)

(defconst latex-to-svg-backend--entry-extensions '(".svg" ".eld" ".log")
  "Extensions of the files a cache entry can have, the leading one first.
An entry is the files named after one content key.  A compiled equation
has an `.svg'; one whose compile failed has no `.svg', only its `.log'
and, when the formula was at fault, its `.eld' failure record.")

(defconst latex-to-svg-backend--format-extensions '(".fmt" ".eld" ".log")
  "Extensions of the files a `.fmt' entry can have, the leading one first.
A `.fmt' entry is the files in `fmt/' named after one key of
`latex-to-svg-backend--format-key': a dump that succeeded leaves the
`.fmt' file and its `.eld' stamp; a dump that failed leaves its `.eld'
stamp, marked failed, and its `.log'.")

(defun latex-to-svg-backend--entry-lead (file &optional extensions)
  "Return the file that dates the cache entry FILE belongs to, or nil.
That is the entry's first existing file in the order of EXTENSIONS,
by default `latex-to-svg-backend--entry-extensions': its SVG, whose
mtime is bumped on every load, else its sidecar, else its log."
  (let ((base (file-name-sans-extension file)))
    (seq-some (lambda (ext)
                (let ((f (concat base ext)))
                  (and (file-exists-p f) f)))
              (or extensions latex-to-svg-backend--entry-extensions))))

(defun latex-to-svg-backend--delete-entry (file &optional extensions)
  "Delete the cache entry FILE belongs to: its files with EXTENSIONS.
EXTENSIONS is as for `latex-to-svg-backend--entry-lead'.  Return the
bytes freed."
  (let ((base (file-name-sans-extension file))
        (freed 0))
    (dolist (ext (or extensions latex-to-svg-backend--entry-extensions))
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
An unusable stamp is treated as \"never collected\", with no warning:
the GC runs and rewrites the stamp, and warns when it cannot (see
`latex-to-svg-backend--record-gc-time')."
  (let ((f (latex-to-svg-backend--gc-stamp-file)))
    (or (and (file-readable-p f)
             (condition-case nil
                 (let ((stamp (with-temp-buffer
                                (insert-file-contents f)
                                (read (current-buffer)))))
                   ;; Parsed, but not a time -- corrupt just the same.
                   (and (numberp stamp) stamp))
               ((end-of-file invalid-read-syntax file-error) nil)))
        0)))

(defun latex-to-svg-backend--record-gc-time ()
  "Persist the current time as the last GC time (for the daily cadence).
A stamp that cannot be written is reported each time: the GC is
requested by no buffer, so there is none to mark.  The cadence is then
not persisted, so the next idle check collects, and warns, again."
  (let ((file (latex-to-svg-backend--gc-stamp-file)))
    (condition-case err
        (with-temp-file file
          (prin1 (float-time) (current-buffer)))
      (file-error
       (display-warning
        'latex-to-svg-backend
        (format "Cannot record the time of the cache collection in %s: %s.
The cache is collected again at every idle check.  %s"
                file (error-message-string err)
                (latex-to-svg-backend--cache-fix))
        :warning)))))

(defconst latex-to-svg-backend--scratch-max-age 1
  "Days after which `latex-to-svg-backend-gc' deletes a scratch directory.
A compile deletes its own (see `latex-to-svg-backend--scratch-dir'),
so one this old was left by an Emacs that stopped during a compile.  A
compile lasts seconds, so the age cannot reach one that runs, in this
session or in another that shares the cache.")

(defun latex-to-svg-backend--gc-scratch ()
  "Delete the scratch directories older than a day.
See `latex-to-svg-backend--scratch-max-age'.  Return the number deleted."
  (let ((dir (expand-file-name "tmp" (latex-to-svg-backend--cache-dir)))
        (now (float-time))
        (deleted 0))
    (dolist (d (and (file-directory-p dir)
                    (directory-files dir t "\\`compile-")))
      (when (> (- now (float-time (file-attribute-modification-time
                                   (file-attributes d))))
               (* latex-to-svg-backend--scratch-max-age 86400))
        (delete-directory d t)
        (cl-incf deleted)))
    deleted))

(defun latex-to-svg-backend--gc-directory (name extensions max-age)
  "Delete the entries in cache subdirectory NAME older than MAX-AGE days.
EXTENSIONS is as for `latex-to-svg-backend--entry-lead', which dates
each entry.  Return a cons (DELETED . BYTES-FREED)."
  (let ((dir (expand-file-name name (latex-to-svg-backend--cache-dir)))
        (regexp (concat (regexp-opt extensions) "\\'"))
        (now (float-time))
        (deleted 0) (freed 0))
    (dolist (f (and (file-directory-p dir)
                    (directory-files-recursively dir regexp)))
      ;; Each entry once, through the file that dates it.
      (when (equal f (latex-to-svg-backend--entry-lead f extensions))
        (let ((mtime (float-time (file-attribute-modification-time
                                  (file-attributes f)))))
          (when (> (- now mtime) (* max-age 86400))
            (cl-incf freed (latex-to-svg-backend--delete-entry f extensions))
            (cl-incf deleted)))))
    (cons deleted freed)))

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

A precompiled `.fmt' file, with its stamp, older than the same age
is deleted too: its mtime is bumped on every compile that loads it
\(see `latex-to-svg-backend--touch-format'), and one still wanted is
dumped again on the next compile.  So are the stamp and the log of a
dump that failed, dated by the stamp.

A compile's scratch directory older than a day, left by an Emacs that
stopped during the compile, is deleted too, also when
`latex-to-svg-backend-cache-max-age' is nil (see
`latex-to-svg-backend--gc-scratch'); it is not counted.

Runs automatically about once a day (see `latex-to-svg-backend-gc-interval');
this command forces a run now.  Returns a cons (DELETED . BYTES-FREED),
DELETED counting equations and `.fmt' files."
  (interactive)
  (let ((equations '(0 . 0)) (formats '(0 . 0)))
    (latex-to-svg-backend--gc-scratch)
    (when-let* ((max-age latex-to-svg-backend-cache-max-age))
      (setq equations (latex-to-svg-backend--gc-directory
                       "svg" latex-to-svg-backend--entry-extensions max-age)
            formats (latex-to-svg-backend--gc-directory
                     "fmt" latex-to-svg-backend--format-extensions max-age)))
    (latex-to-svg-backend--record-gc-time)
    (let ((freed (+ (cdr equations) (cdr formats))))
      (when (called-interactively-p 'interactive)
        (message "latex-to-svg-backend: GC removed %d equation(s) and %d \
.fmt file(s), freed %s"
                 (car equations) (car formats)
                 (file-size-human-readable freed)))
      (cons (+ (car equations) (car formats)) freed))))

;;;###autoload
(defun latex-to-svg-backend-clear-cache ()
  "Delete every cached equation SVG and its `.eld'/`.log' siblings.

Empties the on-disk equation cache (all shards) and the in-memory image
cache; precompiled `.fmt' files are kept (see
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
