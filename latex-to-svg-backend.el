;;; latex-to-svg-backend.el --- LaTeX-to-SVG rendering backend with caching -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg-backend
;; Version: 0.18.1
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
;;   * A third engine, `:engine texres', runs LaTeX through texres, a TeX
;;     distribution in a single executable, and converts its PDF with
;;     `pdftocairo'.  It reads the LaTeX engine's preamble and has its own
;;     `.fmt' file and compile metadata.
;;
;;   * The on-disk SVG is COLOR-INDEPENDENT: dvisvgm `--currentcolor' emits
;;     the default ink as the literal token `currentColor', which is
;;     substituted with the caller's `:color' at display time.  A theme
;;     switch therefore re-tints from cache with no recompile.  The image
;;     background is transparent, so it always matches the buffer.
;;
;;   * The on-disk SVG is SIZE-INDEPENDENT: it is compiled at dvisvgm
;;     `--scale=1' (natural point dimensions, glyphs as outline paths) and
;;     given its width in pixels at display time, computed from the
;;     x-height of the text around it, so equations track the font — again
;;     no recompile.  An inline equation's baseline sits on the line's.
;;
;;   * The preamble is PRECOMPILED once to a LaTeX `.fmt' file with TeX's
;;     `\dump', then loaded by every equation compile with a `%&' first
;;     line (see `latex-to-svg-backend-precompile').  This skips re-parsing
;;     the class and packages (amsmath, ...) on each equation, so compiles
;;     are markedly faster.  It falls back to a full compile when the dump
;;     fails.
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
;;                         x-height)
;;
;; LATEX is placed *verbatim* in the document body, so the caller passes
;; valid body LaTeX and decides inline vs display by the delimiters it uses
;; (`$x$', `\(x\)', `\[x\]', `\begin{equation}...\end{equation}', ...).
;; The backend is deliberately unaware of that distinction.
;;
;; Returns an image now when one can be produced synchronously (cache /
;; on-disk SVG), else nil after scheduling an asynchronous compile.
;; CALLBACK, a function of one argument, is called once for that
;; request: with nil once the SVG is ready, so the caller can re-query
;; and place the image, or with a plist that describes the failure:
;; its kind, engine, message, line and column in LATEX, and log.
;; Concurrent requests for the same equation are coalesced onto a
;; single compile.
;;
;; A formula the engine rejects is recorded and not compiled again;
;; `:fallback latex' typesets it with LaTeX instead,
;; `latex-to-svg-backend-engine-used' says which engine drew a picture,
;; and `latex-to-svg-backend-failure' returns a recorded failure.
;;
;; The backend reads no faces and no frames.  The caller passes the
;; tint as `:color' and the x-height of the text as `:x-height', both
;; read on the frame that shows its buffer; `:background' and `:padding'
;; add a box behind the equation and grow it beyond the ink -- one number
;; for all four sides, or a list of one to four numbers in CSS order, so a
;; left-only gutter is (0 0 0 6).  All apply post-compile, no recompile.
;;
;; Helpers a front-end typically needs for its refresh policy:
;; `latex-to-svg-backend-available-p' and
;; `latex-to-svg-backend-image-width'.

;;; Code:

(eval-when-compile
  (require 'cl-lib))

(require 'latex-to-svg-backend-core)
(require 'latex-to-svg-backend-latex)
(require 'latex-to-svg-backend-ratex)
(require 'latex-to-svg-backend-texres)

;;;; Version

(defconst latex-to-svg-backend-version "0.18.1"
  "The version of the loaded backend, as in the `Version:' header.
A front-end compares it with `version<=' to check that the backend it
loaded has what it needs.")

;;;; Engine

(defun latex-to-svg-backend--engine (engine)
  "Return ENGINE as `latex', `ratex' or `texres'; nil is `latex'.
Signals an error for any other value: a misspelt engine is a caller
bug, and quietly falling back to LaTeX would hide it."
  (pcase engine
    ('nil 'latex)
    ((or 'latex 'ratex 'texres) engine)
    (_ (error "Unknown engine %S: want `latex', `ratex', `texres' or nil"
              engine))))

;;;; Capability

(defun latex-to-svg-backend-tools-available-p (&optional engine)
  "Return non-nil when the programs of ENGINE are found.
ENGINE is `latex' (the default, also nil), `ratex' or `texres', as for
`latex-to-svg-backend'.  The programs are looked up on the variable
`exec-path': `latex' and `dvisvgm' for the LaTeX engine, `render-svg'
for the RaTeX one, `texres' and `pdftocairo' for the texres one."
  (pcase (latex-to-svg-backend--engine engine)
    ('latex (latex-to-svg-backend--latex-tools-available-p))
    ('ratex (latex-to-svg-backend--ratex-tools-available-p))
    ('texres (latex-to-svg-backend--texres-tools-available-p))))

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

(defconst latex-to-svg-backend--cache-version 3
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
not wipe the cache.  Change it by hand, only for a real incompatibility.

2 (0.14.0): an inline equation's SVG gives its baseline (see
`latex-to-svg-backend--baseline-comment'); an older SVG has none, and
would be centred on its line.  3 (0.14.0): every SVG gives the
x-height of its font (see `latex-to-svg-backend--x-height-comment'),
by which it is sized.")

(defun latex-to-svg-backend--inputs ()
  "Return what the engines read from the current buffer, as a plist.
That is `latex-to-svg-backend--latex-inputs', which the texres engine
reads too, and `latex-to-svg-backend--ratex-inputs' together.
`latex-to-svg-backend' reads it once, in the requesting buffer, and
passes it to the cache key, the compile and the fallback: a compile may
start from another compile's sentinel, and the fallback from its own,
where the current buffer is another."
  (append (latex-to-svg-backend--latex-inputs)
          (latex-to-svg-backend--ratex-inputs)))

(defun latex-to-svg-backend--cache-key (latex &optional engine inputs)
  "Return a stable content cache key for LATEX rendered by ENGINE.
ENGINE is `latex' (the default, also nil), `ratex' or `texres'; the
caller has checked it (see `latex-to-svg-backend--engine').  INPUTS is the plist
of `latex-to-svg-backend--inputs', nil meaning the current buffer's.
The engine's input besides LATEX is folded in so changing it
invalidates the cache: the preamble and the macros text for
the LaTeX engine (see `latex-to-svg-backend--latex-cache-salt'; without
a macros text, the key is the one it had before RaTeX was
added), the engine's name and its macros for the RaTeX one, the
engine's name and the LaTeX engine's text for the texres one.  So is
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
                               ((or 'nil 'latex)
                                (latex-to-svg-backend--latex-cache-salt
                                 (or inputs (latex-to-svg-backend--latex-inputs))))
                               ('ratex
                                (latex-to-svg-backend--ratex-cache-salt
                                 (or inputs (latex-to-svg-backend--ratex-inputs))))
                               ('texres
                                (latex-to-svg-backend--texres-cache-salt
                                 (or inputs (latex-to-svg-backend--latex-inputs))))))))

;;;; Compile queue

(defun latex-to-svg-backend--enqueue (key latex waiter &optional metadata engine inputs)
  "Queue WAITER for KEY and schedule a compile if none is queued or running.

KEY identifies the equation; WAITER is what to notify (see
`latex-to-svg-backend--waiter').  LATEX is forwarded to the compile of
ENGINE (`latex', the default, also nil, `ratex' or `texres'):
`latex-to-svg-backend--compile' or `latex-to-svg-backend--texres-compile',
along with METADATA (the INITIAL value for the `.eld' sidecar), or
`latex-to-svg-backend--ratex-compile', which writes no sidecar; all
along with INPUTS (as for
`latex-to-svg-backend--cache-key').
Multiple waiters sharing KEY (the same equation requested more than
once) are coalesced onto a single compile; all are notified when it
finishes.

The compile waits for a slot (see `latex-to-svg-backend--schedule') and
may start from the sentinel of another compile.  So INPUTS, nil meaning
the current buffer's, is read now, and the compile starts in WAITER's
requesting buffer while that is live, where it reads the options that
INPUTS does not hold; when it was killed, the compile reports nothing
\(see `latex-to-svg-backend--with-requester')."
  (let ((pending (gethash key latex-to-svg-backend--pending))
        (inputs (or inputs (latex-to-svg-backend--inputs)))
        (buffer (plist-get waiter :buffer)))
    (puthash key (cons waiter pending) latex-to-svg-backend--pending)
    (unless pending
      (latex-to-svg-backend--schedule
       key
       (lambda ()
         (latex-to-svg-backend--with-requester buffer
           (pcase-exhaustive engine
             ((or 'nil 'latex)
              (latex-to-svg-backend--compile key latex metadata inputs))
             ('ratex
              (latex-to-svg-backend--ratex-compile key latex inputs))
             ('texres
              (latex-to-svg-backend--texres-compile
               key latex metadata inputs)))))
       engine))))

;;;; Failed compiles and the fallback engine

(defun latex-to-svg-backend--sidecar (key)
  "Return the plist in the `.eld' sidecar of the equation of KEY, or nil.
KEY is a content key (see `latex-to-svg-backend--cache-key').  The
sidecar holds compile metadata (see `latex-to-svg-backend-metadata') or
a failure record (see `latex-to-svg-backend--record-failure').

A sidecar that cannot be parsed (truncated by a crash mid-write) yields
nil, but it is not left to rot: only a compile can rewrite it, and the
cached SVG would keep any compile from happening, so the whole cache
entry is discarded (`latex-to-svg-backend--invalidate-key') and the next
render rebuilds both the SVG and the sidecar.  Done at most once per
equation per session, with no warning: the sidecar is cache, and the
backend rebuilds it.  A sidecar that cannot be read at all is reported
once per buffer (see `latex-to-svg-backend--warn')."
  (let ((file (latex-to-svg-backend--meta-file key)))
    (when (file-readable-p file)
      (condition-case err
          (with-temp-buffer
            ;; As `latex-to-svg-backend--record-failure' writes it.
            (let ((coding-system-for-read 'utf-8))
              (insert-file-contents file))
            (read (current-buffer)))
        ;; Unreadable syntax: repairable, by making the entry compile again.
        ((end-of-file invalid-read-syntax)
         (unless (gethash key latex-to-svg-backend--metadata-repaired)
           (puthash key t latex-to-svg-backend--metadata-repaired)
           (latex-to-svg-backend--invalidate-key key))
         nil)
        ;; Not repairable by recompiling -- and the deletions that a repair
        ;; would attempt are exactly what is failing here.  Report it.
        (file-error
         (latex-to-svg-backend--warn
          "reading compile metadata"
          (format "Cannot read %s: %s.
The equation's number, or the record of its failed compile, is lost.
Make the file readable, or set `latex-to-svg-backend-cache-directory' \
to another directory."
                  file (error-message-string err))))))))

(defun latex-to-svg-backend--failed-p (key)
  "Return non-nil when the equation of KEY has a failure record.
KEY is a content key (see `latex-to-svg-backend--cache-key').  See
`latex-to-svg-backend--record-failure'."
  (plist-get (latex-to-svg-backend--sidecar key) :failed))

(defun latex-to-svg-backend--recorded-failure (key engine)
  "Return the failure ENGINE recorded for the equation of KEY, or nil.
KEY is a content key (see `latex-to-svg-backend--cache-key').  The
result is the plist of `latex-to-svg-backend--failure', of kind
`formula', as the compile that failed gave it.  A record written before
0.15.0 holds no message, line or column, so those are nil."
  (when-let* ((record (latex-to-svg-backend--sidecar key))
              ((plist-get record :failed)))
    (latex-to-svg-backend--failure
     'formula engine
     :message (plist-get record :message)
     :line (plist-get record :line)
     :column (plist-get record :column)
     :key key)))

(defun latex-to-svg-backend--fall-back (latex fallback metadata waiter inputs)
  "Take WAITER's request for LATEX over to the engine FALLBACK.
Called from the compile sentinel once the requested engine rejected
LATEX (see `latex-to-svg-backend--compile-failed').  INPUTS is the
requesting buffer's plist of `latex-to-svg-backend--inputs', read when
the request was made: the sentinel's current buffer is another.  LATEX
is compiled with FALLBACK under FALLBACK's own cache key, along with
METADATA, and WAITER's callback is called when that compile ends (see
`latex-to-svg-backend--call-back'): with nil when the SVG is ready, so
the caller re-queries and `latex-to-svg-backend' finds it, and with
FALLBACK's failure otherwise.  When FALLBACK's SVG, or its failure
record, is there already, the callback is called now."
  (let* ((fallback-key (latex-to-svg-backend--cache-key latex fallback inputs))
         (callback (plist-get waiter :callback))
         (failure (latex-to-svg-backend--recorded-failure fallback-key fallback)))
    (cond
     ((file-exists-p (latex-to-svg-backend--svg-file fallback-key))
      (latex-to-svg-backend--call-back callback nil))
     (failure
      (latex-to-svg-backend--call-back callback failure))
     (t (latex-to-svg-backend--enqueue
         fallback-key latex waiter metadata fallback inputs)))))

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

(cl-defun latex-to-svg-backend (latex &key callback metadata engine fallback quiet tentative rescale-by color background padding x-height)
  "Return an SVG image for LATEX, or nil while it compiles.

ENGINE chooses the program that typesets LATEX.  `latex' (the
default, also nil) runs `latex' and `dvisvgm' (options in the
`latex-to-svg-backend-latex' group): full LaTeX, with any package the
preamble loads, from a TeX installation.  `ratex' runs RaTeX's
`render-svg' (options in the `latex-to-svg-backend-ratex' group): one
program and no TeX installation, for the math KaTeX supports and no
packages.  `texres' runs the `pdflatex' of texres, then `pdftocairo'
\(options in the `latex-to-svg-backend-texres' group): full LaTeX with
the LaTeX engine's preamble, from one program instead of a TeX
installation.  Any other value signals an error.  The engine is part
of the cache key, so each engine's SVGs stay cached when a caller
switches to another.  As for COLOR, a front-end owns the user
preference and passes it here.

When ENGINE rejects LATEX -- a RaTeX parse error, or a LaTeX error in
the document -- the failure is recorded in the `.eld' sidecar, and a
later request with the same ENGINE returns nil without compiling.
`latex-to-svg-backend-invalidate' deletes the record, so the next
request compiles again.  A failure that is not the formula's (a missing
program, a crash) is not recorded.  `latex-to-svg-backend-failure'
returns a recorded failure.

FALLBACK is nil (the default: no fallback) or an engine, as for ENGINE,
that typesets LATEX when ENGINE has rejected it: under its own cache
key, so a later request with the same ENGINE and FALLBACK returns the
fallback's picture from cache.  The same LATEX must then be valid for
FALLBACK; a macro defined only in `latex-to-svg-backend-ratex-macros'
fails with LaTeX too.  The first fallback picture in a buffer
is announced with a message naming how many fell back.
`latex-to-svg-backend-engine-used' says which engine drew a picture.

A failed compile warns once per equation per buffer, naming the buffer
and linking to the log; QUIET non-nil drops that warning for this call.
A program that is not found, ENGINE's or FALLBACK's, still warns, once
per buffer per engine and program; the request then returns nil, and
the next request runs the program again.  An Emacs that cannot display
SVG images also warns, once per buffer, even with QUIET.  A buffer
killed before its compile ends gets no warning.

TENTATIVE non-nil says a failure of this request is expected, as for an
equation typeset at each pause while the user types it.  Its failure is
not recorded, so a later request for LATEX compiles it again; CALLBACK
still gets the failure.  Requests for the same equation share one
compile, which is tentative only when every one of them is.

METADATA, when non-nil and `latex-to-svg-backend-metadata-prefix' is set, is the
INITIAL value stored in this equation's `.eld' sidecar (see
`latex-to-svg-backend-metadata'); the FINAL value is captured from the compile
log.  It is only recorded when a compile actually runs (a miss), and
only by the LaTeX and texres engines.

RESCALE-BY (default 1.0) multiplies the base display size for this one
call, on top of the global `latex-to-svg-backend-font-scale'.  The
backend has no inline/display awareness; a front-end that wants display
equations a touch larger than inline passes, say, `:rescale-by 1.1' for
display and nothing for inline.  It is applied at display time only --
same on-disk SVG, no recompile — and folds into the in-memory image cache
key, so the two sizes coexist.

COLOR is the tint, a `#rrggbb' string; it is required whenever
X-HEIGHT is given.  The backend resolves no color names and reads no
faces: the front-end resolves the color on the frame that shows its
buffer.  BACKGROUND paints a box color behind the otherwise transparent
equation (a `#rrggbb' string); nil (the default) keeps it transparent
so it blends into the buffer.  A COLOR or BACKGROUND in any other form
signals an error.  PADDING grows that box
beyond the ink (it scales with the equation): a number of pt applies to
all four sides, and a list of one to four numbers is read in CSS order
-- (ALL), (VERTICAL HORIZONTAL), (TOP HORIZONTAL BOTTOM), (TOP RIGHT
BOTTOM LEFT) -- so (0 0 0 6) is a left gutter and nothing else.  Nil
/ 0 (the default) crops the box to the ink.  All apply
at display time only -- same on-disk SVG, no recompile -- and fold
into the in-memory image cache key, so tinted / boxed / padded
variants coexist.

X-HEIGHT (pixels) is the x-height of the font of the text around the
equation, the height of its lowercase `x'.  The front-end reads it on
the frame that shows the buffer, for example as the ascent of `x' in
`font-get-glyphs' on the `font-at' the equation, and passes it.  The
equation's font is displayed with X-HEIGHT times
`latex-to-svg-backend-font-scale' and RESCALE-BY as its x-height, so at
1.0 the equation's lowercase letters have the height of the text's, as
CSS's `font-size-adjust' matches two fonts.  The x-height of the
equation's font comes from TeX, so a preamble that loads another math
font is followed.  The image is given that width
in pixels, at `:scale' 1.0, and an `:ascent' that puts an inline
equation's baseline on the line's; a display equation is centred.
Nil means the buffer is shown nowhere: the backend still ensures the
size-independent SVG is compiled and cached, but returns nil and
measures nothing.  The caller re-queries once the buffer is shown, and
the image is built then, from cache, with no recompile.  Any other
value than nil or a positive number signals an error.

LATEX is placed *verbatim* in the LaTeX document body, so it must be
valid there: pass math with its delimiters (`$x$', `\\(x\\)', `\\=\\[x\\=\\]')
or a full environment (`\\begin{equation}...\\end{equation}').  The
delimiters also choose inline vs display sizing — the backend does not.
The RaTeX engine has no document body: it removes the outer delimiter
and typesets in text style for `$x$' and `\\(x\\)', in display style
otherwise (see `latex-to-svg-backend--ratex-delimiters').

Returns immediately with:

  * the cached / on-disk equation image when it is ready, or FALLBACK's
    when ENGINE failed;
  * nil when this Emacs cannot display SVG images (see
    `latex-to-svg-backend-available-p'), with a warning once per
    buffer; nothing is compiled and the caller keeps the LaTeX source;
  * nil when ENGINE failed and there is no FALLBACK picture.

When the equation is not yet compiled, returns nil and
schedules an asynchronous compile.  Concurrent requests for the same
equation share one compile.

CALLBACK is a function of one argument, OUTCOME.  It is called exactly
once for every request that returned nil, except one that found the
equation compiled with no X-HEIGHT, which calls nothing, and one
cancelled with `latex-to-svg-backend-cancel'.  OUTCOME is:

  * nil when the SVG is in the cache: the caller re-queries (calls
    `latex-to-svg-backend' again, which now returns the image) and
    places it;
  * otherwise a plist, when the request ended without a picture:

      (:kind KIND :engine ENGINE :message MESSAGE :line LINE
       :column COLUMN :log LOG :program PROGRAM)

    KIND is `formula' when the engine rejected LATEX, which is recorded,
    and `setup' for a missing program, a crash, or an Emacs that cannot
    display SVG images, which is not.  ENGINE is the engine that failed:
    with FALLBACK, the fallback's, the last engine that tried.  MESSAGE
    is one line, for a tooltip.  LINE (1-based) and COLUMN (0-based)
    locate the error in LATEX, where TeX stopped, or are nil: when TeX
    stopped outside LATEX, when texres cut a long line short, and always
    for RaTeX.  LOG is the saved log, or nil.  PROGRAM is the program
    that was not found, for a `setup' failure.  QUIET does not change
    OUTCOME, so a caller that shows the error itself passes QUIET.

When the request finds a failure record, or a failure ends it before
it returns (a missing program, no SVG support), CALLBACK is called from
a timer, so it never runs before `latex-to-svg-backend' returns.

Call within the target buffer: the engines read their options there (see
`latex-to-svg-backend--inputs'), so a buffer-local value, from a
`.dir-locals.el' say, applies to that buffer's equations."
  (setq engine (latex-to-svg-backend--engine engine)
        fallback (and fallback (latex-to-svg-backend--engine fallback)))
  (when (eq fallback engine)
    (setq fallback nil))
  (latex-to-svg-backend--hex-color color :color)
  (latex-to-svg-backend--hex-color background :background)
  (unless (or (null x-height) (and (numberp x-height) (> x-height 0)))
    (error "Invalid :x-height %S: want a positive number of pixels"
           x-height))
  (when (and x-height (null color))
    (error "Missing :color: required with :x-height"))
  (latex-to-svg-backend--report-obsolete-options)
  (let ((latex-to-svg-backend--in-request t))
    (if (not (latex-to-svg-backend-available-p))
        (progn
          (latex-to-svg-backend--report-no-svg)
          (latex-to-svg-backend--call-back
           callback (latex-to-svg-backend--failure
                     'setup engine
                     :message latex-to-svg-backend--no-svg-message))
          nil)
      (let* ((inputs (latex-to-svg-backend--inputs))
             (key (latex-to-svg-backend--cache-key latex engine inputs))
             (compiled (file-exists-p (latex-to-svg-backend--svg-file key)))
             (image (and compiled
                         (latex-to-svg-backend--cached-image
                          key rescale-by color background padding x-height)))
             (failure (and (not compiled)
                           (latex-to-svg-backend--recorded-failure key engine))))
        (cond
         ;; SVG on disk and an x-height: return the display image.
         (image)
         ;; Compiled, but no x-height (buffer shown nowhere): defer.
         ;; The caller re-renders when the buffer is displayed.  Nothing
         ;; is pending, so CALLBACK is not called.
         (compiled nil)
         ;; ENGINE rejected LATEX before: do not compile it again.
         (failure
          (cond
           ((null fallback)
            (unless quiet
              (latex-to-svg-backend--report-failure
               key latex engine (plist-get failure :message)))
            (latex-to-svg-backend--call-back callback failure)
            nil)
           (t
            (let ((image (latex-to-svg-backend
                          latex :callback callback :metadata metadata
                          :engine fallback :quiet quiet
                          :tentative tentative
                          :rescale-by rescale-by :color color
                          :background background :padding padding
                          :x-height x-height)))
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
                        latex fallback metadata waiter inputs)))
                tentative)
               metadata engine inputs))
            nil))))))

(defun latex-to-svg-backend-cancel (callback)
  "Cancel the request made with CALLBACK: its outcome is not wanted.
CALLBACK is the function passed as `:callback' to
`latex-to-svg-backend', compared with `eq': the caller makes one
closure per request and keeps it.  CALLBACK is not called, unless the
request ended while `latex-to-svg-backend' ran: that call waits in a
timer and still comes.  Return non-nil when a request was cancelled.

A compile that no other request waits for is stopped: a queued one is
taken off the queue, a running one has its process killed and its
scratch directory deleted, and its slot goes to the next compile.  A
request handed to FALLBACK is cancelled there.  A stopped compile
records no failure, so a later request for the same LATEX compiles
it again."
  (let ((mine (lambda (waiter) (eq (plist-get waiter :callback) callback)))
        keys)
    (maphash (lambda (key waiters)
               (when (seq-some mine waiters)
                 (push key keys)))
             latex-to-svg-backend--pending)
    (dolist (key keys)
      (if-let* ((others (seq-remove
                         mine (gethash key latex-to-svg-backend--pending))))
          (puthash key others latex-to-svg-backend--pending)
        (latex-to-svg-backend--stop key)))
    (and keys t)))

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
only that one is dropped.  Call it in the buffer the render was made
for, as that buffer's options are part of the key (see
`latex-to-svg-backend--inputs')."
  (latex-to-svg-backend--invalidate-key
   (latex-to-svg-backend--cache-key latex (latex-to-svg-backend--engine engine))))

(defun latex-to-svg-backend--invalidate-key (key)
  "Forget the cached render of the equation of KEY.
KEY is a content key (see `latex-to-svg-backend--cache-key').  See
`latex-to-svg-backend-invalidate', which computes it in the current
buffer; this takes it from a caller that computed it elsewhere."
  (let* ((file (latex-to-svg-backend--svg-file key))
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
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (member seen latex-to-svg-backend--warned)
            (setq latex-to-svg-backend--warned
                  (delete seen latex-to-svg-backend--warned))))))))

;;;###autoload
(defun latex-to-svg-backend-metadata (latex &optional engine)
  "Return cached compile metadata for LATEX rendered by ENGINE, or nil.
ENGINE is as for `latex-to-svg-backend'.  Only the LaTeX engine
and the texres engine write metadata, so this is always nil for
`ratex'.

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
                 (latex-to-svg-backend--cache-key latex engine))))
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
           (latex-to-svg-backend--failed-p key)
           (file-exists-p (latex-to-svg-backend--svg-file
                           (latex-to-svg-backend--cache-key latex fallback))))
      fallback))))

;;;###autoload
(defun latex-to-svg-backend-failure (latex &optional engine fallback)
  "Return the recorded failure a request for LATEX resolves to, or nil.
ENGINE and FALLBACK are as for `latex-to-svg-backend'.  The result is
the plist a request's callback gets when it ends without a picture (see
`latex-to-svg-backend'), of kind `formula': ENGINE's when it failed on
LATEX, or with FALLBACK, FALLBACK's when it failed too.  Nil when ENGINE
has a picture, when FALLBACK has one, and when no failure is recorded.
A front-end calls it with no request in flight, for a tooltip or a
redraw.  Call it in the buffer the request was made for, as for
`latex-to-svg-backend-engine-used'."
  (let* ((engine (latex-to-svg-backend--engine engine))
         (fallback (and fallback (latex-to-svg-backend--engine fallback)))
         (key (latex-to-svg-backend--cache-key latex engine)))
    (unless (file-exists-p (latex-to-svg-backend--svg-file key))
      (when-let* ((failure (latex-to-svg-backend--recorded-failure key engine)))
        (if (and fallback (not (eq fallback engine)))
            (let ((fallback-key (latex-to-svg-backend--cache-key latex fallback)))
              (unless (file-exists-p (latex-to-svg-backend--svg-file fallback-key))
                (latex-to-svg-backend--recorded-failure fallback-key fallback)))
          failure)))))

(provide 'latex-to-svg-backend)

;;; latex-to-svg-backend.el ends here
