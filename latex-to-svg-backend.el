;;; latex-to-svg-backend.el --- LaTeX-to-SVG rendering backend with caching -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg-backend
;; Version: 0.10.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tex, math, images

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
;; A small, buffer-agnostic backend that turns a LaTeX math string into an
;; SVG image suitable for overlaying in an Emacs buffer.  It is the
;; rendering backend behind `agent-shell-math-renderer' (math in agent-shell's
;; chat output) and the `latex-to-svg' preview stack (Org and Markdown).
;; A front-end finds the equations and places the images; the typesetting,
;; caching and sizing happen here.
;;
;; Design (why it is cheap to recolor and rescale):
;;
;;   * Equations are compiled with `latex' + `dvisvgm' to a standalone SVG,
;;     named on disk after its own content (SHA-1 of LaTeX + preamble +
;;     style).  Each unique equation therefore compiles at most once, and
;;     the cache is shared across every front-end.
;;
;;   * A second engine, RaTeX's `render-svg', needs no TeX installation
;;     and typesets the math KaTeX supports; a caller chooses it per call
;;     with `:engine ratex'.  It produces the same color- and
;;     size-independent SVG; the `.fmt' precompilation and compile metadata
;;     below are the LaTeX engine's.
;;
;;   * The on-disk SVG is COLOR-INDEPENDENT: dvisvgm `--currentcolor' emits
;;     the default ink as the literal token `currentColor', which is
;;     substituted with the buffer foreground at display time.  A theme
;;     switch therefore re-tints from cache with no recompile.  The image
;;     background is transparent, so it always matches the buffer.
;;
;;   * The on-disk SVG is SIZE-INDEPENDENT: it is compiled at dvisvgm
;;     `--scale=1' (natural point dimensions, glyphs as outline paths) and
;;     scaled at display time via `create-image' :scale, computed from the
;;     buffer font height so equations track the font — again no recompile.
;;
;;   * The preamble is PRECOMPILED once to a LaTeX format file (`.fmt') via
;;     the `mylatexformat' package, then loaded by every equation compile
;;     with a `%&' first line (see `latex-to-svg-backend-precompile').  This
;;     skips re-parsing the class and packages (amsmath, ...) on each
;;     equation, so compiles are markedly faster.  It falls back to a full
;;     compile when `mylatexformat' is unavailable or the dump fails.
;;
;;   * The cache is SHARDED into 256 subdirectories (by the first two hex
;;     characters of the content key) so no single directory accumulates
;;     every equation, and is bounded by an age-limited garbage collector
;;     (`latex-to-svg-backend-gc') that deletes equations untouched for a
;;     while and runs automatically about once a day (see
;;     `latex-to-svg-backend-gc-interval').
;;
;; Public entry point:
;;
;;   (latex-to-svg-backend LATEX &key callback metadata engine fallback
;;                         quiet rescale-by color background padding
;;                         font-height)
;;
;; LATEX is placed *verbatim* in the document body, so the caller passes
;; valid body LaTeX and decides inline vs display by the delimiters it uses
;; (`$x$', `\(x\)', `\[x\]', `\begin{equation}...\end{equation}', ...).
;; The backend is deliberately unaware of that distinction.
;;
;; Returns an image now when one can be produced synchronously (cache /
;; on-disk SVG / placeholder), else nil after scheduling an asynchronous
;; compile; CALLBACK (a zero-argument function) is invoked once the SVG is
;; ready, so the caller can re-query and place the image.  Concurrent
;; requests for the same equation are coalesced onto a single compile.
;;
;; A formula the engine rejects is recorded and not compiled again;
;; `:fallback latex' typesets it with LaTeX instead, and
;; `latex-to-svg-backend-engine-used' says which engine drew a picture.
;;
;; The optional `:color'/`:background'/`:padding' keys override the
;; display-time tint, an optional box color behind the equation, and padding
;; that grows that box beyond the ink -- one number for all four sides, or a
;; list of one to four numbers in CSS order, so a left-only gutter is
;; (0 0 0 6) (all apply post-compile, no recompile); a front-end owns the
;; user-facing preference and passes it through.
;;
;; Helpers a front-end typically needs for its refresh policy:
;; `latex-to-svg-backend-available-p', `latex-to-svg-backend-appearance',
;; `latex-to-svg-backend-display-scale', and
;; `latex-to-svg-backend-foreground-color'.

;;; Code:

(eval-when-compile
  (require 'cl-lib))

(require 'latex-to-svg-backend-core)
(require 'latex-to-svg-backend-latex)
(require 'latex-to-svg-backend-ratex)

;;;; Engine

(defun latex-to-svg-backend--engine (engine)
  "Return ENGINE as `latex' or `ratex'; nil is `latex'.
Signals an error for any other value: a misspelt engine is a caller
bug, and quietly falling back to LaTeX would hide it."
  (pcase engine
    ('nil 'latex)
    ((or 'latex 'ratex) engine)
    (_ (error "Unknown engine %S: want `latex', `ratex' or nil" engine))))

;;;; Capability

(defun latex-to-svg-backend-tools-available-p (&optional engine)
  "Return non-nil when the programs of ENGINE are found.
ENGINE is `latex' (the default, also nil) or `ratex', as for
`latex-to-svg-backend'.  The programs are looked up on the variable
`exec-path': `latex' and `dvisvgm' for the LaTeX engine, `render-svg'
for the RaTeX one."
  (pcase (latex-to-svg-backend--engine engine)
    ('latex (latex-to-svg-backend--latex-tools-available-p))
    ('ratex (latex-to-svg-backend--ratex-tools-available-p))))

;;;; State

;; Content keys whose unreadable `.eld' sidecar has been discarded this
;; session, so the repair is attempted at most once per equation: a sidecar
;; that comes back unreadable after a fresh compile would otherwise recompile
;; on every query.
(defvar latex-to-svg-backend--metadata-repaired (make-hash-table :test 'equal)
  "Content keys whose unreadable metadata sidecar was discarded this session.")

;; The equations of this buffer that were drawn by a fallback engine and
;; not yet reported, or t once they were: the message is once per buffer,
;; as a buffer-scoped warning is.
(defvar-local latex-to-svg-backend--fell-back nil
  "Keys that fell back in this buffer and are to be reported, or t.")

;;;; Cache key

(defconst latex-to-svg-backend--cache-version 1
  "Version number mixed into every cache file name.
See `latex-to-svg-backend--cache-key'.
Raise it by one when a code change makes the *old cached SVGs wrong* even
though the LaTeX and preamble are unchanged — for example if we change a
`dvisvgm' flag, the compile command, or the shape of the SVG we produce.
Because the number is part of the file name, raising it gives every file
a new name, so the stale ones are simply never found again (they get
cleaned up later by the normal cache GC) and everything is recompiled
fresh.

Do NOT tie this to the TeX/dvisvgm version — upgrading TeX Live should
not wipe the cache.  Change it by hand, only for a real incompatibility.")

(defun latex-to-svg-backend--cache-key (latex &optional engine)
  "Return a stable content cache key for LATEX rendered by ENGINE.
ENGINE is `latex' (the default, also nil) or `ratex'; the caller has
checked it (see `latex-to-svg-backend--engine').
The engine's input besides LATEX is folded in so changing it
invalidates the cache: the preamble for the LaTeX engine (the key is
the one it had before RaTeX was added), the engine's name and
`latex-to-svg-backend-ratex-macros' for the RaTeX one.  So is
`latex-to-svg-backend--cache-version', so a pipeline change re-keys warm
caches.  LATEX is the verbatim document body, so any change to it —
including inline vs display delimiters or an injected `\setcounter' for
equation numbering — changes the key on its own.  The key names the
on-disk SVG, which is both font- AND color-independent (equations
are compiled with dvisvgm `--currentcolor', then sized and tinted at
display time), so neither size nor color is part of this key."
  (secure-hash 'sha1 (format "%d\0%s\0%s"
                             latex-to-svg-backend--cache-version
                             latex
                             (pcase-exhaustive engine
                               ((or 'nil 'latex) (latex-to-svg-backend--preamble))
                               ('ratex (latex-to-svg-backend--ratex-cache-salt))))))

;;;; Compile queue

(defun latex-to-svg-backend--enqueue (key latex waiter &optional metadata engine)
  "Queue WAITER for KEY and start a compile if none is running.

KEY identifies the equation; WAITER is what to notify (see
`latex-to-svg-backend--waiter').  LATEX is forwarded to the compile of
ENGINE (`latex', the default, also nil, or `ratex'):
`latex-to-svg-backend--compile', along with METADATA (the INITIAL value
for the `.eld' sidecar), or `latex-to-svg-backend--ratex-compile', which
writes no sidecar.
Multiple waiters sharing KEY (the same equation requested more than
once) are coalesced onto a single in-flight compile; all are notified
when it finishes."
  (let ((pending (gethash key latex-to-svg-backend--pending)))
    (puthash key (cons waiter pending) latex-to-svg-backend--pending)
    (unless pending
      (pcase-exhaustive engine
        ((or 'nil 'latex) (latex-to-svg-backend--compile key latex metadata))
        ('ratex (latex-to-svg-backend--ratex-compile key latex))))))

;;;; Failed compiles and the fallback engine

(defun latex-to-svg-backend--sidecar (latex engine key)
  "Return the plist in the `.eld' sidecar of LATEX rendered by ENGINE, or nil.
KEY is the content key of LATEX and ENGINE.  The sidecar holds compile
metadata (see `latex-to-svg-backend-metadata') or a failure record (see
`latex-to-svg-backend--record-failure').

A sidecar that cannot be parsed (truncated by a crash mid-write) yields
nil, but it is not left to rot: only a compile can rewrite it, and the
cached SVG would keep any compile from happening, so LATEX's whole cache
entry is discarded (`latex-to-svg-backend-invalidate') and the next
render rebuilds both the SVG and the sidecar.  Done at most once per
equation per session."
  (let ((file (latex-to-svg-backend--meta-file key)))
    (when (file-readable-p file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (read (current-buffer)))
        ;; Unreadable syntax: repairable, by making the entry compile again.
        ((end-of-file invalid-read-syntax)
         (latex-to-svg-backend--warn-once
          "discarding an unreadable metadata sidecar" err)
         (unless (gethash key latex-to-svg-backend--metadata-repaired)
           (puthash key t latex-to-svg-backend--metadata-repaired)
           (latex-to-svg-backend-invalidate latex engine))
         nil)
        ;; Not repairable by recompiling -- and the deletions that a repair
        ;; would attempt are exactly what is failing here.  Report it.
        (file-error
         (latex-to-svg-backend--warn-once
          "reading compile metadata" err 'buffer))))))

(defun latex-to-svg-backend--failed-p (latex engine key)
  "Return non-nil when LATEX has a failure record for ENGINE.
KEY is the content key of LATEX and ENGINE.  See
`latex-to-svg-backend--record-failure'."
  (plist-get (latex-to-svg-backend--sidecar latex engine key) :failed))

(defun latex-to-svg-backend--fallback-unavailable (key latex engine fallback buffer quiet)
  "Report that LATEX failed with ENGINE and FALLBACK cannot be run.
KEY is the content key of LATEX and ENGINE, and BUFFER the requesting
buffer, or nil when it was killed.  The missing programs are a
configuration problem, reported once per session even when QUIET is
non-nil; the failure of LATEX is reported as any other unless QUIET."
  (when (latex-to-svg-backend--mark-once
         (format "fallback unavailable/%s" fallback))
    (display-warning
     'latex-to-svg-backend
     (format "Falling back to %s needs %s, which %s not found.
Install %s (see %s), or turn off the fallback option of the package \
that shows the equations."
             (latex-to-svg-backend--engine-name fallback)
             (pcase-exhaustive fallback
               ('latex (format "`%s' and `%s'"
                               latex-to-svg-backend-latex-program
                               latex-to-svg-backend-dvisvgm-program))
               ('ratex (format "`%s'" latex-to-svg-backend-ratex-program)))
             (if (eq fallback 'latex) "were" "was")
             (if (eq fallback 'latex) "them" "it")
             (pcase-exhaustive fallback
               ('latex "`latex-to-svg-backend-latex-program' and \
`latex-to-svg-backend-dvisvgm-program'")
               ('ratex "`latex-to-svg-backend-ratex-program'")))
     :warning))
  (unless quiet
    (latex-to-svg-backend--report-failure key latex engine buffer)))

(defun latex-to-svg-backend--fall-back (latex engine fallback metadata waiter)
  "Take WAITER's request for LATEX over from ENGINE to FALLBACK.
Called from the compile sentinel once ENGINE rejected LATEX (see
`latex-to-svg-backend--compile-failed').  LATEX is compiled with
FALLBACK under FALLBACK's own cache key, along with METADATA, and
WAITER's callback fires when that SVG is ready; the caller then
re-queries and `latex-to-svg-backend' finds it.  When FALLBACK's SVG, or
its failure record, is there already, the callback fires now.  When
FALLBACK's programs are missing, that is reported (see
`latex-to-svg-backend--fallback-unavailable')."
  (let ((key (latex-to-svg-backend--cache-key latex engine))
        (fallback-key (latex-to-svg-backend--cache-key latex fallback))
        (buffer (plist-get waiter :buffer)))
    (cond
     ((not (latex-to-svg-backend-tools-available-p fallback))
      (latex-to-svg-backend--fallback-unavailable
       key latex engine fallback (and (buffer-live-p buffer) buffer)
       (plist-get waiter :quiet)))
     ((or (file-exists-p (latex-to-svg-backend--svg-file fallback-key))
          (latex-to-svg-backend--failed-p latex fallback fallback-key))
      (funcall (plist-get waiter :callback)))
     (t (latex-to-svg-backend--enqueue
         fallback-key latex waiter metadata fallback)))))

(defun latex-to-svg-backend--report-fallbacks (buffer engine fallback)
  "Say how many equations in BUFFER FALLBACK drew because ENGINE failed.
Once per buffer: afterwards `latex-to-svg-backend--fell-back' is t."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (consp latex-to-svg-backend--fell-back)
        (let ((n (length latex-to-svg-backend--fell-back)))
          (setq latex-to-svg-backend--fell-back t)
          (message "latex-to-svg-backend: %d %s in %s fell back to %s: \
%s could not parse %s"
                   n (if (= n 1) "equation" "equations") (buffer-name)
                   (latex-to-svg-backend--engine-name fallback)
                   (latex-to-svg-backend--engine-name engine)
                   (if (= n 1) "it" "them")))))))

(defun latex-to-svg-backend--note-fallback (key engine fallback)
  "Note that FALLBACK drew the equation of KEY, which ENGINE failed.
KEY is the content key for ENGINE.  The equations noted in the current
buffer are reported together, with a message, a second after the first
\(see `latex-to-svg-backend--report-fallbacks'): a fallback picture is
typeset in the fallback engine's style, and the message says why it
differs from the others."
  (let ((noted latex-to-svg-backend--fell-back))
    (unless (or (eq noted t) (member key noted))
      (setq latex-to-svg-backend--fell-back (cons key noted))
      (unless noted
        (run-with-timer 1 nil #'latex-to-svg-backend--report-fallbacks
                        (current-buffer) engine fallback)))))

;;;; Public entry point

(cl-defun latex-to-svg-backend (latex &key callback metadata engine fallback quiet rescale-by color background padding font-height)
  "Return an SVG image for LATEX, or nil while it compiles.

ENGINE chooses the program that typesets LATEX.  `latex' (the
default, also nil) runs `latex' and `dvisvgm' (options in the
`latex-to-svg-backend-latex' group): full LaTeX, with any package the
preamble loads, from a TeX installation.  `ratex' runs RaTeX's
`render-svg' (options in the `latex-to-svg-backend-ratex' group): one
program and no TeX installation, for the math KaTeX supports and no
packages.  Any other value signals an error.  The engine is part of
the cache key, so each engine's SVGs stay cached when a caller
switches to the other.  As for COLOR, a front-end owns the user
preference and passes it here.

When ENGINE rejects LATEX -- a RaTeX parse error, or a LaTeX error in
the document -- the failure is recorded in the `.eld' sidecar, and a
later request with the same ENGINE returns nil without compiling.
`latex-to-svg-backend-invalidate' deletes the record, so the next
request compiles again.  A failure that is not the formula's (a missing
program, a crash) is not recorded.

FALLBACK is nil (the default: no fallback) or an engine, as for ENGINE,
that typesets LATEX when ENGINE has rejected it: under its own cache
key, so a later request with the same ENGINE and FALLBACK returns the
fallback's picture from cache.  The same LATEX must then be valid for
FALLBACK; a macro defined only in `latex-to-svg-backend-ratex-macros'
fails with LaTeX too.  When FALLBACK's programs are missing, that is
warned about once per session.  The first fallback picture in a buffer
is announced with a message naming how many fell back.
`latex-to-svg-backend-engine-used' says which engine drew a picture.

A failed compile warns once per equation per buffer, naming the buffer
and linking to the log; QUIET non-nil drops that warning for this call.
Configuration problems, such as missing fallback programs, still warn.

METADATA, when non-nil and `latex-to-svg-backend-metadata-prefix' is set, is the
INITIAL value stored in this equation's `.eld' sidecar (see
`latex-to-svg-backend-metadata'); the FINAL value is captured from the compile
log.  It is only recorded when a compile actually runs (a miss), and
only by the LaTeX engine.

RESCALE-BY (default 1.0) multiplies the base display size for this one
call, on top of the global `latex-to-svg-backend-font-scale'.  The
backend has no inline/display awareness; a front-end that wants display
equations a touch larger than inline passes, say, `:rescale-by 1.1' for
display and nothing for inline.  It is applied at display time only --
same on-disk SVG, no recompile — and folds into the in-memory image cache
key, so the two sizes coexist.

COLOR overrides the tint for this one call (a color string — `#rrggbb'
or any name `color-name-to-rgb' understands); nil (the default) tints
to the buffer foreground (`latex-to-svg-backend-foreground-color'), which
tracks the theme.  BACKGROUND paints a box color behind the otherwise
transparent equation (a color string); nil (the default) keeps it
transparent so it blends into the buffer.  PADDING grows that box
beyond the ink (it scales with the equation): a number of pt applies to
all four sides, and a list of one to four numbers is read in CSS order
-- (ALL), (VERTICAL HORIZONTAL), (TOP HORIZONTAL BOTTOM), (TOP RIGHT
BOTTOM LEFT) -- so (0 0 0 6) is a left gutter and nothing else.  Nil
/ 0 (the default) crops the box to the ink.  All apply
at display time only -- same on-disk SVG, no recompile -- and fold
into the in-memory image cache key, so tinted / boxed / padded
variants coexist.  The backend has no tint policy of its own beyond
following the buffer face; a front-end owns the user preference and
passes it here.

FONT-HEIGHT (pixels) is the buffer font height to size against.  A
front-end that knows the buffer's actual display frame measures
`default-font-height' there and passes it, so sizing never depends on
which frame is selected.  When omitted, the selected frame is measured
if graphical.  When no height is known (omitted and the selected frame
is non-graphical -- e.g. an async/daemon render of a buffer shown
nowhere), the backend still ensures the (size-independent) SVG is
compiled and cached, but returns nil instead of sizing against a guess:
the caller re-queries once the buffer is displayed (where a trustworthy
height exists) and the image is built then, from cache, with no
recompile.

LATEX is placed *verbatim* in the LaTeX document body, so it must be
valid there: pass math with its delimiters (`$x$', `\\(x\\)', `\\=\\[x\\=\\]')
or a full environment (`\\begin{equation}...\\end{equation}').  The
delimiters also choose inline vs display sizing — the backend does not.
The RaTeX engine has no document body: it removes the outer delimiter
and typesets in text style for `$x$' and `\\(x\\)', in display style
otherwise (see `latex-to-svg-backend--ratex-delimiters').

Returns immediately with:

  * the placeholder panel image, when `latex-to-svg-backend-use-placeholder'
    is set or the engine's programs are unavailable (see
    `latex-to-svg-backend--placeholder');
  * the cached / on-disk equation image when it is ready, or FALLBACK's
    when ENGINE failed;
  * nil when equations aren't renderable (see
    `latex-to-svg-backend-available-p') — the caller keeps the raw text;
  * nil when ENGINE failed and there is no FALLBACK picture.

When the equation is renderable but not yet compiled, returns nil and
schedules an asynchronous compile; CALLBACK (a zero-argument function)
is invoked once, when the SVG is ready, so the caller can re-query
\(call `latex-to-svg-backend' again, which now returns the image) and place
it.  Concurrent requests for the same equation share one compile.

The image is tinted to the current buffer foreground and scaled to
the buffer font at build time, so call within the target buffer."
  (setq engine (latex-to-svg-backend--engine engine)
        fallback (and fallback (latex-to-svg-backend--engine fallback)))
  (when (eq fallback engine)
    (setq fallback nil))
  (when (latex-to-svg-backend-available-p)
    (cond
     ((or latex-to-svg-backend-use-placeholder
          (not (latex-to-svg-backend-tools-available-p engine)))
      (latex-to-svg-backend--placeholder latex))
     (t
      (let* ((key (latex-to-svg-backend--cache-key latex engine))
             (compiled (file-exists-p (latex-to-svg-backend--svg-file key)))
             (image (and compiled
                         (latex-to-svg-backend--cached-image
                          key rescale-by color background padding font-height))))
        (cond
         ;; SVG on disk and a trustworthy size: return the display image.
         (image)
         ;; Compiled, but no size context yet (buffer shown nowhere): defer.
         ;; The caller re-renders when the buffer is displayed.
         (compiled nil)
         ;; ENGINE rejected LATEX before: do not compile it again.
         ((latex-to-svg-backend--failed-p latex engine key)
          (cond
           ((null fallback)
            (unless quiet
              (latex-to-svg-backend--report-failure
               key latex engine (current-buffer)))
            nil)
           ((not (latex-to-svg-backend-tools-available-p fallback))
            (latex-to-svg-backend--fallback-unavailable
             key latex engine fallback (current-buffer) quiet)
            nil)
           (t
            (let ((image (latex-to-svg-backend
                          latex :callback callback :metadata metadata
                          :engine fallback :quiet quiet
                          :rescale-by rescale-by :color color
                          :background background :padding padding
                          :font-height font-height)))
              (when image
                (latex-to-svg-backend--note-fallback key engine fallback))
              image))))
         ;; Not compiled: ensure it is (eagerly, even with no size context),
         ;; so it is ready when the buffer is later displayed; CALLBACK fires
         ;; on completion so the caller re-queries and sizes it then.
         (t (when callback
              (latex-to-svg-backend--enqueue
               key latex
               (latex-to-svg-backend--waiter
                callback quiet
                (and fallback
                     (lambda (waiter)
                       (latex-to-svg-backend--fall-back
                        latex engine fallback metadata waiter))))
               metadata engine))
            nil)))))))

;;;###autoload
(defun latex-to-svg-backend-invalidate (latex &optional engine)
  "Forget any cached render of LATEX and force a recompile next time.

Deletes LATEX's on-disk SVG (named after LATEX's content) and drops every
in-memory image built from it (all sizes / colors), so a subsequent
`latex-to-svg-backend' for LATEX recompiles from scratch.  Use this to recover
from a stale or corrupt cached SVG — ordinarily the content hash makes
that impossible, so this is an escape hatch, not part of the normal
flow.

It also deletes a failure record (see `latex-to-svg-backend'), so an
equation that failed is compiled again, and forgets that the failure
was reported, so a failure that remains is reported again.

ENGINE is the engine the render was made with, as for
`latex-to-svg-backend': each engine's SVG has its own cache entry, so
only that one is dropped."
  (let* ((key (latex-to-svg-backend--cache-key
               latex (latex-to-svg-backend--engine engine)))
         (file (latex-to-svg-backend--svg-file key))
         (meta (latex-to-svg-backend--meta-file key))
         (prefix (concat key "@"))
         (stale nil))
    (when (file-exists-p file)
      (delete-file file))
    ;; Keep the metadata sidecar coupled to its SVG.
    (when (file-exists-p meta)
      (delete-file meta))
    (maphash (lambda (k _v)
               (when (string-prefix-p prefix k)
                 (push k stale)))
             latex-to-svg-backend--image-cache)
    (dolist (k stale)
      (remhash k latex-to-svg-backend--image-cache))
    (let ((seen (concat "compile failed/" key)))
      (remhash seen latex-to-svg-backend--warned)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (assoc seen latex-to-svg-backend--warned-in-buffer)
            (setq latex-to-svg-backend--warned-in-buffer
                  (assoc-delete-all
                   seen latex-to-svg-backend--warned-in-buffer))))))))

;;;###autoload
(defun latex-to-svg-backend-metadata (latex &optional engine)
  "Return cached compile metadata for LATEX rendered by ENGINE, or nil.
ENGINE is as for `latex-to-svg-backend'.  Only the LaTeX engine
writes metadata, so this is always nil for `ratex'.

Returns the plist `(:nums (INITIAL . FINAL))' read from LATEX's
`.eld' sidecar: INITIAL is the caller's `:metadata' at render time and
FINAL is the first integer the compile emitted on a
`latex-to-svg-backend-metadata-prefix' line.  Available on cache hit or miss
once LATEX has compiled at least once with the prefix set; nil otherwise,
including when the sidecar holds a failure record instead (see
`latex-to-svg-backend').

A sidecar that cannot be parsed also yields nil, and discards LATEX's
cache entry so the next render rebuilds it (see
`latex-to-svg-backend--sidecar')."
  (let* ((engine (latex-to-svg-backend--engine engine))
         (plist (latex-to-svg-backend--sidecar
                 latex engine (latex-to-svg-backend--cache-key latex engine))))
    (unless (plist-get plist :failed)
      plist)))

;;;###autoload
(defun latex-to-svg-backend-engine-used (latex &optional engine fallback)
  "Return the engine whose picture a request for LATEX resolves to, or nil.
ENGINE and FALLBACK are as for `latex-to-svg-backend'.  The result is
ENGINE when its SVG is cached, FALLBACK when ENGINE failed on LATEX (see
`latex-to-svg-backend') and FALLBACK's SVG is cached, and nil when
neither has a picture.  A front-end calls it once it has the image, to
say which engine typeset it."
  (let* ((engine (latex-to-svg-backend--engine engine))
         (fallback (and fallback (latex-to-svg-backend--engine fallback)))
         (key (latex-to-svg-backend--cache-key latex engine)))
    (cond
     ((file-exists-p (latex-to-svg-backend--svg-file key)) engine)
     ((and fallback
           (not (eq fallback engine))
           (latex-to-svg-backend--failed-p latex engine key)
           (file-exists-p (latex-to-svg-backend--svg-file
                           (latex-to-svg-backend--cache-key latex fallback))))
      fallback))))

(provide 'latex-to-svg-backend)

;;; latex-to-svg-backend.el ends here
