;;; latex-to-svg-backend-latex.el --- LaTeX renderer of latex-to-svg-backend -*- lexical-binding: t -*-

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
;; The LaTeX renderer of `latex-to-svg-backend': it compiles an equation
;; with `latex' + `dvisvgm' and precompiles the preamble to a LaTeX format
;; file (`.fmt').  Load `latex-to-svg-backend', not this file.

;;; Code:

(require 'latex-to-svg-backend-core)

(defgroup latex-to-svg-backend-latex nil
  "The LaTeX renderer of `latex-to-svg-backend': `latex' + `dvisvgm'."
  :group 'latex-to-svg-backend
  :prefix "latex-to-svg-backend-")

;;;; Customization

(defcustom latex-to-svg-backend-latex-program "latex"
  "Program that compiles a LaTeX document to DVI."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-dvisvgm-program "dvisvgm"
  "Program that converts DVI to SVG."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-preamble
  "\\documentclass[varwidth,border=2pt]{standalone}
\\usepackage{amsmath}
\\usepackage{amssymb}
\\usepackage{xcolor}"
  "LaTeX preamble (everything before `\\begin{document}') for equations.
The `standalone' class crops the page tightly to the equation, so
no `preview' package is required.  The `varwidth' option is what lets
the verbatim body use *display* math — `\\[...\\]' and display
environments like `equation'/`align' — not just inline `$...$'
\(plain `standalone' typesets its body as a single horizontal box and
errors with \"Missing $ inserted\" on display math).  dvisvgm's
`--exact-bbox' then crops to the actual ink.

See also `latex-to-svg-backend-appended-preamble' for adding extra packages
without replacing this base."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-appended-preamble ""
  "Extra LaTeX code appended after `latex-to-svg-backend-preamble'.
Use this to load additional packages (e.g. `\\usepackage{braket}',
`\\usepackage{physics}') without replacing the base preamble.  The
value is folded into the cache key, so changing it automatically
invalidates cached SVGs."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-line-width nil
  "Maximum typeset width of an equation, as a LaTeX dimension string.
This caps the width of the `varwidth' box the body is set in (the
`standalone' class's `\\sa@width').  When nil (the default) the class's
default is used (`\\linewidth', ~345pt).

A *numbered* display sets its number flush right at this width, and TeX
drops it onto a second line when the equation is wider, so the number
stays on the line only while the equation fits within it.  Raise it,
say to \"20cm\", when wide numbered equations wrap their number; lower
it, say to \"6cm\", to tuck the number closer to the equation when every
equation is short.  Either way this just moves the right margin; the
one rule is not to set it below your widest numbered equation (which
would wrap).  Unnumbered content is unaffected (cropped to its ink).

The value is folded into the cache key, so changing it re-renders."
  :type '(choice (const :tag "Class default (~345pt)" nil)
                 (string :tag "LaTeX dimension"))
  ;; This string is interpolated verbatim into the preamble
  ;; (`\def\sa@width{...}'), so a file-local value is LaTeX code unless it is
  ;; validated.  Accept only a bare signed decimal plus a TeX unit: no brace,
  ;; backslash or space can get through, so nothing can escape the `\def'.
  :safe (lambda (v)
          (or (null v)
              (and (stringp v)
                   (string-match-p
                    (concat "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)"
                            "\\(?:pt\\|pc\\|in\\|bp\\|cm\\|mm\\|dd\\|cc\\|sp\\|ex\\|em\\)\\'")
                    v))))
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-precompile t
  "When non-nil, precompile the preamble to a LaTeX format (`.fmt') file.

The class and packages in `latex-to-svg-backend-preamble' /
`latex-to-svg-backend-appended-preamble' are dumped once, with the
`mylatexformat' package, to a format file keyed by the preamble text;
every equation compile then loads it with a `%&' first line instead of
re-reading the preamble, which speeds each compile up noticeably.

Requires `mylatexformat.ltx' on the TeX search path (part of most TeX
distributions).  When it is missing, or the dump fails, or a compile
using the format later fails, the engine transparently falls back to
embedding the full preamble in each equation — correctness never depends
on this option.  A stale format after a TeX toolchain upgrade is detected
and rebuilt automatically (the binary is newer than the `.fmt');
`latex-to-svg-backend-flush-format' is the manual escape hatch."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-metadata-prefix nil
  "Line prefix marking compile metadata to capture, or nil to disable.
When a string, after each successful compile the first integer on a LaTeX
log line beginning with it (the FINAL value) is paired with the caller's
`:metadata' value (the INITIAL value) and stored as the plist
`(:nums (INITIAL . FINAL))' in the equation's `.eld' sidecar next to
its SVG, exposed by `latex-to-svg-backend-metadata' (on cache hit or miss).

So the caller supplies INITIAL directly (a value it already knows, in
Elisp), and only FINAL — the thing the compile computes — travels through
LaTeX, emitted with `\\typeout{PREFIX \\arabic{COUNTER}}'.  Keep that line
short: TeX wraps log lines near column 80."
  :type '(choice (const :tag "Disabled" nil) string)
  ;; Inert: only ever matched against compile-log lines
  ;; (`string-prefix-p'), never written into the document.
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'latex-to-svg-backend-latex)

;;;; State

;; Precompiled-preamble (.fmt) bookkeeping, keyed by format key (a hash of
;; the preamble text + LaTeX program, see `latex-to-svg-backend--format-key').
;; `--format-checked' records keys whose `.fmt' was verified fresh this
;; session, so the freshness (mtime) check runs at most once per key;
;; `--format-blocklist' records keys whose format produced a compile
;; failure, so precompilation is abandoned for them for the rest of the
;; session and the engine falls back to full compiles.
(defvar latex-to-svg-backend--format-checked (make-hash-table :test 'equal)
  "Format keys whose `.fmt' has been verified fresh this session.")

(defvar latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal)
  "Format keys whose `.fmt' failed a compile; precompilation skipped for them.")

;;;; Capability

(defun latex-to-svg-backend--latex-tools-available-p ()
  "Return non-nil when the LaTeX-to-SVG toolchain is on the variable `exec-path'."
  (and (executable-find latex-to-svg-backend-latex-program)
       (executable-find latex-to-svg-backend-dvisvgm-program)))

;;;; Preamble

(defun latex-to-svg-backend--preamble ()
  "Return the full LaTeX preamble: the base plus any appended packages.
This is the exact text embedded before `\\begin{document}' in a full
compile, and the text dumped into the precompiled format file.  When
`latex-to-svg-backend-line-width' is set, a `\\sa@width' override is
appended so the `varwidth' box uses that width (see that variable)."
  (concat
   latex-to-svg-backend-preamble
   (unless (string-empty-p latex-to-svg-backend-appended-preamble)
     (concat "\n" latex-to-svg-backend-appended-preamble))
   ;; Override `standalone's varwidth width (`\sa@width', default
   ;; `\linewidth').  Placed last so it wins over the class default.
   (when latex-to-svg-backend-line-width
     (format "\n\\makeatletter\\def\\sa@width{%s}\\makeatother"
             latex-to-svg-backend-line-width))))

;;;; Preamble precompilation (.fmt)

;; Speedup: dump the preamble (class + packages) to a LaTeX format file once,
;; then load it from every equation compile with a `%&' first line instead of
;; re-reading and re-loading amsmath/xcolor/... each time.  Uses the
;; `mylatexformat' package.  Entirely optional: on any hiccup the engine
;; falls back to embedding the full preamble in each equation, so a `.fmt' is
;; a pure performance optimization, never a correctness dependency.

(defun latex-to-svg-backend--latex-binary ()
  "Return the path to the LaTeX executable, or nil.
Honours an absolute `latex-to-svg-backend-latex-program', else resolves the
command name on variable `exec-path'.  Used for the format freshness check."
  (let ((prog (car (split-string latex-to-svg-backend-latex-program))))
    (if (file-name-absolute-p prog)
        (and (file-executable-p prog) prog)
      (executable-find prog))))

(defun latex-to-svg-backend--latex-format-name ()
  "Return the base LaTeX format to preload when dumping (e.g. \"latex\").
The `&NAME' the `-ini' dump reads before `mylatexformat.ltx'."
  (file-name-nondirectory (car (split-string latex-to-svg-backend-latex-program))))

(defun latex-to-svg-backend--format-key ()
  "Return the cache key naming the precompiled preamble format file.
Folds in the full preamble and the LaTeX program, so any change to
either yields a distinct `.fmt' (and a rebuild on the next render)."
  (secure-hash 'sha1 (format "%s\0%s"
                             (latex-to-svg-backend--preamble)
                             latex-to-svg-backend-latex-program)))

(defun latex-to-svg-backend--fmt-dir ()
  "Return the subdirectory holding precompiled `.fmt' files, creating it."
  (latex-to-svg-backend--subdir "fmt"))

(defun latex-to-svg-backend--format-file (fkey)
  "Return the precompiled format file path (`.fmt') for FKEY."
  (expand-file-name (concat fkey ".fmt") (latex-to-svg-backend--fmt-dir)))

(defun latex-to-svg-backend--precompile-available-p ()
  "Return non-nil when the preamble can be dumped to a `.fmt'.
Requires the `mylatexformat' package: `mylatexformat.ltx' must be
findable via `kpsewhich'.

A `kpsewhich' that exits non-zero just means the package is not installed.
A `kpsewhich' that cannot be started at all (moved by a toolchain upgrade
mid-session) is a different matter: it is reported once
\(`latex-to-svg-backend--warn-once') and treated as unavailable, so the
engine falls back to full compiles."
  (and (executable-find "kpsewhich")
       (eql 0 (condition-case err
                  (call-process "kpsewhich" nil nil nil "mylatexformat.ltx")
                (file-error
                 (latex-to-svg-backend--warn-once
                  "probing for mylatexformat" err))))))

(defun latex-to-svg-backend--build-format (fkey)
  "Dump the preamble to a precompiled format file for FKEY, synchronously.
Return the `.fmt' path on success, nil on failure.  Writes the preamble
followed by `\\endofdump' to a scratch `.tex' in the `fmt/' subdirectory
and runs `latex-to-svg-backend-latex-program' in `-ini' mode with
`mylatexformat.ltx' to dump `<cache>/fmt/FKEY.fmt'.  The build log is in the
`*latex-to-svg-backend-precompile-log*' buffer for inspection.

A preamble that will not dump exits non-zero and yields nil (the caller
falls back to a full compile, which reports the real LaTeX error).  A LaTeX
program that cannot be started at all is reported once instead."
  (let* ((dir (latex-to-svg-backend--fmt-dir))
         (base (expand-file-name fkey dir))
         (fmt (concat base ".fmt"))
         (pre-tex (concat base ".tex"))
         (log (concat base ".log"))
         (buffer (get-buffer-create "*latex-to-svg-backend-precompile-log*")))
    (with-current-buffer buffer (erase-buffer))
    ;; Pin UTF-8: see `latex-to-svg-backend--compile' on why the encoding is
    ;; fixed on write rather than declared with `inputenc'.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file pre-tex
        (insert (latex-to-svg-backend--preamble) "\n\\endofdump\n")))
    (message "latex-to-svg-backend: precompiling LaTeX preamble...")
    (let ((rv (condition-case err
                  (call-process latex-to-svg-backend-latex-program nil buffer nil
                                (concat "-output-directory=" dir)
                                "-ini"
                                (concat "-jobname=" fkey)
                                (concat "&" (latex-to-svg-backend--latex-format-name))
                                "mylatexformat.ltx" pre-tex)
                ;; The program was on `exec-path' when the toolchain was
                ;; checked but cannot be started now (a TeX Live upgrade
                ;; mid-session moves it).  Report it once; the caller falls
                ;; back to a full compile, which reports its own failure.
                (file-error
                 (latex-to-svg-backend--warn-once
                  "dumping the LaTeX preamble" err)))))
      (delete-file pre-tex)
      (if (and (eql rv 0) (file-exists-p fmt))
          (progn (delete-file log) fmt)
        (delete-file fmt)
        nil))))

(defun latex-to-svg-backend--ensure-format ()
  "Return a fresh precompiled preamble format file path, or nil.
Builds the `.fmt' on first use (synchronously, once per session per
preamble) and caches it on disk.  Rebuilds it when the LaTeX binary is
newer than the `.fmt' (e.g. after a TeX toolchain upgrade, which would
otherwise fail every compile with a format-version mismatch).  Returns
nil — so the caller uses a full compile — when precompilation is off,
`mylatexformat' is unavailable, the dump fails, or the format has been
blocklisted after an earlier failure."
  (when latex-to-svg-backend-precompile
    (let ((fkey (latex-to-svg-backend--format-key)))
      (unless (gethash fkey latex-to-svg-backend--format-blocklist)
        (let ((fmt (latex-to-svg-backend--format-file fkey))
              (latex-bin (latex-to-svg-backend--latex-binary)))
          (cond
           ;; Verified fresh already this session.
           ((and (gethash fkey latex-to-svg-backend--format-checked)
                 (file-exists-p fmt))
            fmt)
           ;; On disk and newer than the engine binary -> trust it.
           ((and (file-exists-p fmt)
                 (or (null latex-bin)
                     (file-newer-than-file-p fmt latex-bin)))
            (puthash fkey t latex-to-svg-backend--format-checked)
            fmt)
           ;; Missing or stale -> (re)build, if mylatexformat is available.
           ((latex-to-svg-backend--precompile-available-p)
            (delete-file fmt)
            (if-let* ((built (latex-to-svg-backend--build-format fkey)))
                (progn
                  (puthash fkey t latex-to-svg-backend--format-checked)
                  built)
              ;; The dump failed.  Give up on this preamble for the session:
              ;; retrying would run a synchronous `latex -ini' for every
              ;; equation, and a preamble that will not dump does not start
              ;; dumping on the next attempt.
              (latex-to-svg-backend--block-format fmt)
              nil))))))))

(defun latex-to-svg-backend--block-format (format-file)
  "Abandon FORMAT-FILE and skip precompilation for its preamble this session.
Deletes the `.fmt' (if any) and blocklists its key, so `--ensure-format'
returns nil for this preamble for the rest of the session and the engine
falls back to full compiles.  Warns once — one warning per preamble, since
the blocklist short-circuits every later call.

Called from the two ways precompilation can fail: the dump itself failed
\(see `latex-to-svg-backend--build-format'; the log stays in the
`*latex-to-svg-backend-precompile-log*' buffer), or the dump succeeded but a
compile that loaded it failed.  In the latter case the same equation is
about to be retried with the full inline preamble, so a genuinely broken
equation is not mistaken for a broken format."
  (let ((fkey (file-name-base format-file)))
    (puthash fkey t latex-to-svg-backend--format-blocklist)
    (remhash fkey latex-to-svg-backend--format-checked)
    (delete-file format-file)
    (display-warning
     'latex-to-svg-backend
     "Precompiled LaTeX preamble failed; falling back to full compiles."
     :warning)))

;;;###autoload
(defun latex-to-svg-backend-flush-format ()
  "Delete all precompiled preamble format files and forget them.

Removes every `.fmt' in the cache `fmt/' subdirectory and clears this session's
freshness and blocklist tracking, so the next render dumps a fresh
format from the current preamble.  An escape hatch for a stale format
the automatic freshness check missed — normally a TeX toolchain upgrade
is handled on its own (the binary is newer than the `.fmt'), so this is
rarely needed."
  (interactive)
  (clrhash latex-to-svg-backend--format-checked)
  (clrhash latex-to-svg-backend--format-blocklist)
  (let ((dir (expand-file-name "fmt" (latex-to-svg-backend--cache-dir))))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\.fmt\\'"))
        (delete-file f)))))

;;;; Compile

(defun latex-to-svg-backend--write-metadata (key dir initial)
  "Write KEY's `.eld' sidecar pairing INITIAL with the compile's FINAL.
Scans the just-finished compile's `equation.log' in scratch DIR for the
first integer on a line beginning with `latex-to-svg-backend-metadata-prefix'
\(FINAL), and writes `(:nums (INITIAL . FINAL))' to `<KEY>.eld'.
INITIAL is the caller's value (from `latex-to-svg-backend's `:metadata'), stored
verbatim.  Writes nothing when the prefix is nil or no FINAL was found.
Called on a successful compile, before DIR is cleaned up."
  (when latex-to-svg-backend-metadata-prefix
    (let ((log (expand-file-name "equation.log" dir))
          (final nil))
      (when (file-readable-p log)
        (with-temp-buffer
          (let ((coding-system-for-read 'raw-text))
            (insert-file-contents log))
          (goto-char (point-min))
          (while (and (not final) (not (eobp)))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (when (string-prefix-p latex-to-svg-backend-metadata-prefix line)
                (let ((rest (substring line (length latex-to-svg-backend-metadata-prefix))))
                  (when (string-match "-?[0-9]+" rest)
                    (setq final (string-to-number (match-string 0 rest)))))))
            (forward-line 1))))
      (when final
        (condition-case err
            (with-temp-file (latex-to-svg-backend--meta-file key)
              (prin1 (list :nums (cons initial final)) (current-buffer)))
          ;; This runs in the compile sentinel, *before* the pending callbacks
          ;; fire: signalling here would leave a successfully compiled equation
          ;; unplaced.  The sidecar is a cache, so report the failure once and
          ;; let the equation through.
          (file-error
           (latex-to-svg-backend--warn-once "writing compile metadata" err)))))))

(defun latex-to-svg-backend--compile (key latex &optional metadata no-format)
  "Asynchronously compile LATEX to the color-independent cache SVG for KEY.
METADATA, when non-nil, is stored as the INITIAL value in KEY's `.eld'
sidecar alongside the FINAL captured from the log (see
`latex-to-svg-backend--write-metadata').

LATEX is placed verbatim in the document body (the caller supplies
valid body LaTeX and chooses inline vs display via delimiters).
Writes a standalone LaTeX document, runs `latex-to-svg-backend-latex-program'
then `latex-to-svg-backend-dvisvgm-program' in a scratch directory, and on
success caches the SVG and notifies every callback queued for KEY
\(see `latex-to-svg-backend--enqueue').  The scratch directory is removed when
the process exits.

The preamble is loaded from a precompiled format file (`.fmt') when one
is available (see `latex-to-svg-backend-precompile'), via a `%&' first line;
otherwise the full preamble is embedded in the document.  On failure,
if a format was used it may be the culprit: the format is abandoned (see
`latex-to-svg-backend--block-format') and the same equation is retried once with
the full inline preamble.  Only when a full-preamble compile fails is
the log saved and a warning emitted (see `latex-to-svg-backend--compile-failed')
and queued callbacks dropped.  NO-FORMAT forces that inline path (it is
set on the retry).

No color is baked in: the equation's default ink is emitted as the
literal `currentColor' (dvisvgm `--currentcolor'), so the SVG is
color-independent and is tinted to the buffer foreground at display
time (`latex-to-svg-backend--load-svg-image').  A theme change therefore
re-tints from cache without recompiling."
  (let* ((dir (make-temp-file "latex-to-svg-backend" t))
         (tex (expand-file-name "equation.tex" dir))
         (dvi (expand-file-name "equation.dvi" dir))
         (svg (latex-to-svg-backend--svg-file key))
         (format-file (and (not no-format) (latex-to-svg-backend--ensure-format)))
         (cleanup (lambda () (delete-directory dir t)))
         (output-buffer (generate-new-buffer
                         (format " *latex-to-svg-backend-%s*" key))))
    ;; Pin UTF-8 on write.  LaTeX has read UTF-8 by default since its
    ;; 2018-04-01 release, so the encoding belongs here and not in an
    ;; `inputenc' line: adding a package to the preamble would rehash
    ;; `--cache-key' and the `.fmt' key, discarding every cached SVG and
    ;; format for every user, to declare what the engine already writes.
    ;; Unpinned, an equation carrying a character the user's default coding
    ;; system cannot encode (an alpha under a Latin-1 language environment,
    ;; say) makes `write-region' *prompt* -- fatal in a background compile,
    ;; and no `.tex' is written at all.  Same hazard the log copy guards
    ;; (`--compile-failed'), but this file carries the user's own math.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file tex
        (if format-file
            ;; Load the precompiled preamble: the `%&' line must be first,
            ;; and names the format file by absolute path without its
            ;; `.fmt' extension.  The class + packages are already in the
            ;; format, so only the document body is compiled here.
            (insert "%& " (file-name-sans-extension format-file) "\n"
                    "\\begin{document}\n"
                    latex "\n"
                    "\\end{document}\n")
          (insert (latex-to-svg-backend--preamble) "\n"
                  "\\begin{document}\n"
                  ;; LATEX is inserted verbatim: it already carries its own
                  ;; math delimiters / environment (chosen by the
                  ;; front-end), which also decide inline vs display
                  ;; sizing.  No `\color' — `--currentcolor' below turns
                  ;; the default (black) ink into the `currentColor' token,
                  ;; tinted at display.
                  latex "\n"
                  "\\end{document}\n"))))
    ;; Compile at dvisvgm scale 1: the SVG is vector (glyphs are outline
    ;; paths via --no-fonts), so the scale doesn't affect quality, and the
    ;; displayed size is set later by `latex-to-svg-backend-display-scale'.  Fixing
    ;; it at 1 means the SVG carries the equation's natural point dimensions.
    ;; `--currentcolor' rewrites the default ink to the `currentColor' token
    ;; so the file is color-independent (tinted at display time).
    (latex-to-svg-backend--run-process-chain
     dir output-buffer
     (list
      (list 'latex
            (list latex-to-svg-backend-latex-program
                  "-interaction=nonstopmode"
                  "-halt-on-error"
                  tex)
            dvi)
      (list 'dvisvgm
            (list latex-to-svg-backend-dvisvgm-program
                  "--no-fonts"
                  "--exact-bbox"
                  "--currentcolor"
                  "--scale=1"
                  "-o"
                  svg
                  dvi)
            svg))
     (lambda (success)
       (let ((retry-format (and (not success) format-file)))
         (unwind-protect
             (cond
              (success
               ;; Capture compile metadata before DIR is cleaned up.
               (latex-to-svg-backend--write-metadata key dir metadata)
               (latex-to-svg-backend--notify-pending key))
              ;; A failed precompiled-format attempt is retried once with the
              ;; full inline preamble; keep the pending callback queue intact.
              (retry-format
               (latex-to-svg-backend--block-format format-file))
              ;; Genuine failure (full preamble): persist diagnostics.
              (t
               (latex-to-svg-backend--compile-failed
                key latex dir
                (latex-to-svg-backend--process-output output-buffer))))
           (unless retry-format
             (remhash key latex-to-svg-backend--pending))
           (when (buffer-live-p output-buffer)
             (kill-buffer output-buffer))
           (funcall cleanup))
         (when retry-format
           (latex-to-svg-backend--compile key latex metadata t)))))))

(provide 'latex-to-svg-backend-latex)

;;; latex-to-svg-backend-latex.el ends here
