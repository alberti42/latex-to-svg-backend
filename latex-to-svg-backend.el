;;; latex-to-svg-backend.el --- LaTeX-to-SVG rendering engine with caching -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg-backend
;; Version: 0.9.0
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
;; A small, buffer-agnostic engine that turns a LaTeX math string into an
;; SVG image suitable for overlaying in an Emacs buffer.  It is the
;; rendering engine behind `agent-shell-math-renderer' (math in agent-shell's
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
;;   * A second renderer, RaTeX's `render-svg', needs no TeX installation
;;     and typesets the math KaTeX supports (see
;;     `latex-to-svg-backend-renderer').  It produces the same color- and
;;     size-independent SVG; the `.fmt' precompilation and compile metadata
;;     below are the LaTeX renderer's.
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
;;     with a `%&' first line (see `latex-to-svg-backend-precompile').  This skips
;;     re-parsing the class and packages (amsmath, ...) on each equation, so
;;     compiles are markedly faster.  It falls back to a full compile when
;;     `mylatexformat' is unavailable or the dump fails.
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
;;   (latex-to-svg-backend LATEX &key callback color background padding font-height)
;;
;; LATEX is placed *verbatim* in the document body, so the caller passes
;; valid body LaTeX and decides inline vs display by the delimiters it uses
;; (`$x$', `\(x\)', `\[x\]', `\begin{equation}...\end{equation}', ...).
;; The engine is deliberately unaware of that distinction.
;;
;; Returns an image now when one can be produced synchronously (cache /
;; on-disk SVG / placeholder), else nil after scheduling an asynchronous
;; compile; CALLBACK (a zero-argument function) is invoked once the SVG is
;; ready, so the caller can re-query and place the image.  Concurrent
;; requests for the same equation are coalesced onto a single compile.
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
;; `latex-to-svg-backend-display-scale', and `latex-to-svg-backend-foreground-color'.

;;; Code:

(eval-when-compile
  (require 'cl-lib))

(require 'latex-to-svg-backend-core)
(require 'latex-to-svg-backend-latex)
(require 'latex-to-svg-backend-ratex)

;;;; Customization

(defcustom latex-to-svg-backend-renderer 'latex
  "Renderer that typesets equations.
`latex' runs `latex' and `dvisvgm' (options in the
`latex-to-svg-backend-latex' group): full LaTeX, with any package the
preamble loads, from a TeX installation.  `ratex' runs RaTeX's
`render-svg' (options in the `latex-to-svg-backend-ratex' group): one
program and no TeX installation, for the math KaTeX supports and no
packages.

The renderer is part of the cache key, so each renderer's SVGs stay
cached when you switch to the other."
  :type '(choice (const :tag "LaTeX (latex + dvisvgm)" latex)
                 (const :tag "RaTeX (render-svg)" ratex))
  ;; Not `:safe': it decides which program runs.
  :group 'latex-to-svg-backend)

(defun latex-to-svg-backend--renderer ()
  "Return `latex-to-svg-backend-renderer', signalling if it names no renderer."
  (pcase latex-to-svg-backend-renderer
    ((or 'latex 'ratex) latex-to-svg-backend-renderer)
    (other (user-error "Unknown `latex-to-svg-backend-renderer': %S" other))))

;;;; Capability

(defun latex-to-svg-backend-tools-available-p ()
  "Return non-nil when the programs of `latex-to-svg-backend-renderer' are found.
They are looked up on the variable `exec-path': `latex' and `dvisvgm'
for the LaTeX renderer, `render-svg' for the RaTeX one."
  (pcase (latex-to-svg-backend--renderer)
    ('latex (latex-to-svg-backend--latex-tools-available-p))
    ('ratex (latex-to-svg-backend--ratex-tools-available-p))))

;;;; State

;; Content keys whose unreadable `.eld' sidecar has been discarded this
;; session, so the repair is attempted at most once per equation: a sidecar
;; that comes back unreadable after a fresh compile would otherwise recompile
;; on every query.
(defvar latex-to-svg-backend--metadata-repaired (make-hash-table :test 'equal)
  "Content keys whose unreadable metadata sidecar was discarded this session.")

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

(defun latex-to-svg-backend--cache-key (latex)
  "Return a stable content cache key for LATEX.
The renderer's input besides LATEX is folded in so changing it
invalidates the cache: the preamble for the LaTeX renderer (the key is
the one it had before RaTeX was added), the renderer's name and
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
                             (pcase (latex-to-svg-backend--renderer)
                               ('latex (latex-to-svg-backend--preamble))
                               ('ratex (latex-to-svg-backend--ratex-cache-salt))))))

;;;; Compile queue

(defun latex-to-svg-backend--enqueue (key latex callback &optional metadata)
  "Queue CALLBACK for KEY and start a compile if none is running.

KEY identifies the equation; LATEX is forwarded to the compile of
`latex-to-svg-backend-renderer': `latex-to-svg-backend--compile', along
with METADATA (the INITIAL value for the `.eld' sidecar), or
`latex-to-svg-backend--ratex-compile', which writes no sidecar.
Multiple callbacks sharing KEY (the same equation requested more than
once) are coalesced onto a single in-flight compile; all are notified
when it finishes."
  (let ((pending (gethash key latex-to-svg-backend--pending)))
    (puthash key (cons callback pending) latex-to-svg-backend--pending)
    (unless pending
      (pcase (latex-to-svg-backend--renderer)
        ('latex (latex-to-svg-backend--compile key latex metadata))
        ('ratex (latex-to-svg-backend--ratex-compile key latex))))))

;;;; Public entry point

(cl-defun latex-to-svg-backend (latex &key callback metadata rescale-by color background padding font-height)
  "Return an SVG image for LATEX, or nil while it compiles.

METADATA, when non-nil and `latex-to-svg-backend-metadata-prefix' is set, is the
INITIAL value stored in this equation's `.eld' sidecar (see
`latex-to-svg-backend-metadata'); the FINAL value is captured from the compile
log.  It is only recorded when a compile actually runs (a miss), and
only by the LaTeX renderer.

RESCALE-BY (default 1.0) multiplies the base display size for this one
call, on top of the global `latex-to-svg-backend-font-scale'.  The engine has no
inline/display awareness; a front-end that wants display equations a
touch larger than inline passes, say, `:rescale-by 1.1' for display and
nothing for inline.  It is applied at display time only -- same on-disk SVG,
no recompile — and folds into the in-memory image cache key, so the two
sizes coexist.

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
variants coexist.  The engine has no tint policy of its own beyond
following the buffer face; a front-end owns the user preference and
passes it here.

FONT-HEIGHT (pixels) is the buffer font height to size against.  A
front-end that knows the buffer's actual display frame measures
`default-font-height' there and passes it, so sizing never depends on
which frame is selected.  When omitted, the selected frame is measured
if graphical.  When no height is known (omitted and the selected frame
is non-graphical -- e.g. an async/daemon render of a buffer shown
nowhere), the engine still ensures the (size-independent) SVG is
compiled and cached, but returns nil instead of sizing against a guess:
the caller re-queries once the buffer is displayed (where a trustworthy
height exists) and the image is built then, from cache, with no
recompile.

LATEX is placed *verbatim* in the LaTeX document body, so it must be
valid there: pass math with its delimiters (`$x$', `\\(x\\)', `\\[x\\]')
or a full environment (`\\begin{equation}...\\end{equation}').  The
delimiters also choose inline vs display sizing — the engine does not.
The RaTeX renderer has no document body: it removes the outer delimiter
and typesets in text style for `$x$' and `\\(x\\)', in display style
otherwise (see `latex-to-svg-backend--ratex-delimiters').

Returns immediately with:

  * the placeholder panel image, when `latex-to-svg-backend-use-placeholder'
    is set or the renderer's programs are unavailable (see
    `latex-to-svg-backend--placeholder');
  * the cached / on-disk equation image when it is ready;
  * nil when equations aren't renderable (see
    `latex-to-svg-backend-available-p') — the caller keeps the raw text.

When the equation is renderable but not yet compiled, returns nil and
schedules an asynchronous compile; CALLBACK (a zero-argument function)
is invoked once, when the SVG is ready, so the caller can re-query
\(call `latex-to-svg-backend' again, which now returns the image) and place
it.  Concurrent requests for the same equation share one compile.

The image is tinted to the current buffer foreground and scaled to
the buffer font at build time, so call within the target buffer."
  (when (latex-to-svg-backend-available-p)
    (cond
     ((or latex-to-svg-backend-use-placeholder
          (not (latex-to-svg-backend-tools-available-p)))
      (latex-to-svg-backend--placeholder latex))
     (t
      (let* ((key (latex-to-svg-backend--cache-key latex))
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
         ;; Not compiled: ensure it is (eagerly, even with no size context),
         ;; so it is ready when the buffer is later displayed; CALLBACK fires
         ;; on completion so the caller re-queries and sizes it then.
         (t (when callback
              (latex-to-svg-backend--enqueue key latex callback metadata))
            nil)))))))

;;;###autoload
(defun latex-to-svg-backend-invalidate (latex)
  "Forget any cached render of LATEX and force a recompile next time.

Deletes LATEX's on-disk SVG (named after LATEX's content) and drops every
in-memory image built from it (all sizes / colors), so a subsequent
`latex-to-svg-backend' for LATEX recompiles from scratch.  Use this to recover
from a stale or corrupt cached SVG — ordinarily the content hash makes
that impossible, so this is an escape hatch, not part of the normal
flow."
  (let* ((key (latex-to-svg-backend--cache-key latex))
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
      (remhash k latex-to-svg-backend--image-cache))))

;;;###autoload
(defun latex-to-svg-backend-metadata (latex)
  "Return cached compile metadata for LATEX, or nil.

Returns the plist `(:nums (INITIAL . FINAL))' read from LATEX's
`.eld' sidecar: INITIAL is the caller's `:metadata' at render time and
FINAL is the first integer the compile emitted on a
`latex-to-svg-backend-metadata-prefix' line.  Available on cache hit or miss
once LATEX has compiled at least once with the prefix set; nil otherwise.

A sidecar that cannot be parsed (truncated by a crash mid-write) also
yields nil, but it is not left to rot: only a compile can rewrite it, and
the cached SVG would keep any compile from happening, so LATEX's whole
cache entry is discarded (`latex-to-svg-backend-invalidate') and the next
render rebuilds both the SVG and the sidecar.  Done at most once per
equation per session."
  (let* ((key (latex-to-svg-backend--cache-key latex))
         (file (latex-to-svg-backend--meta-file key)))
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
           (latex-to-svg-backend-invalidate latex))
         nil)
        ;; Not repairable by recompiling -- and the deletions that a repair
        ;; would attempt are exactly what is failing here.  Report it.
        (file-error
         (latex-to-svg-backend--warn-once
          "reading compile metadata" err 'buffer))))))

(provide 'latex-to-svg-backend)

;;; latex-to-svg-backend.el ends here
