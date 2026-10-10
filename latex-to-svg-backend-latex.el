;;; latex-to-svg-backend-latex.el --- LaTeX engine of latex-to-svg-backend -*- lexical-binding: t -*-

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
;; The LaTeX engine of `latex-to-svg-backend': it compiles an equation
;; with `latex' + `dvisvgm' and precompiles the preamble to a LaTeX `.fmt'
;; file.  Load `latex-to-svg-backend', not this file.

;;; Code:

(require 'latex-to-svg-backend-core)
(require 'project)

(defgroup latex-to-svg-backend-latex nil
  "The LaTeX engine of `latex-to-svg-backend': `latex' + `dvisvgm'."
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
the verbatim body use *display* math — `\\=\\[...\\=\\]' and display
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
invalidates cached SVGs.

Set in a project's `.dir-locals.el', it is dumped into a `.fmt' file of
that project, and `\\input' looks for its files in the project root, as
for `latex-to-svg-backend-preamble-not-precompiled'.  After editing a
file it loads, `latex-to-svg-backend-invalidate-format' makes the next
compile dump the `.fmt' file again."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-preamble-not-precompiled ""
  "LaTeX code written after the preamble and not precompiled.
Meant to be set per project in `.dir-locals.el', to the definitions a
project's equations need, typically `\\input{macros.tex}'.  `\\input'
looks for the file in the project root (`project-root'), or in
`default-directory' outside a project, so `\\input{paper/macros.tex}'
names a file below the root.

Unlike `latex-to-svg-backend-appended-preamble', this is not dumped into
the precompiled `.fmt' file (see `latex-to-svg-backend-precompile'): it
is written into every compile.  That adds no `.fmt' file per project,
but it is read again on every compile, so packages belong in
`latex-to-svg-backend-appended-preamble', where they are dumped once.

The value and the directory are folded into the cache key; the contents
of `macros.tex' are not, so after editing it the equations have to be
compiled again (`latex-to-svg-backend-invalidate').  The RaTeX engine
ignores this option."
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
  "When non-nil, precompile the preamble to a LaTeX `.fmt' file.

The class and packages in `latex-to-svg-backend-preamble' /
`latex-to-svg-backend-appended-preamble' are dumped once, with TeX's
`\\dump', to a `.fmt' file keyed by the preamble text; every equation
compile then loads it with a `%&' first line instead of re-reading the
preamble, which speeds each compile up noticeably.

When the dump fails, or a compile that loaded the `.fmt' file fails,
the backend falls back to embedding the full preamble in each equation —
correctness never depends on this option.  A `.fmt' file dumped by
another LaTeX binary (after a TeX toolchain upgrade, or with another TeX
on the variable `exec-path') is detected and dumped again;
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

;; Bookkeeping of the precompiled `.fmt' files, keyed by
;; `latex-to-svg-backend--format-key' (a hash of the preamble text + LaTeX
;; program).  `--format-checked' records keys whose `.fmt' file was verified
;; fresh this session, so the freshness check runs at most once per key;
;; `--format-blocklist' records keys whose `.fmt' file produced a compile
;; failure, so precompilation is abandoned for them for the rest of the
;; session and the backend falls back to full compiles.
(defvar latex-to-svg-backend--format-checked (make-hash-table :test 'equal)
  "Keys of the `.fmt' files verified fresh this session.")

(defvar latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal)
  "Keys of the `.fmt' files that failed a compile; precompilation skipped.")

(defvar latex-to-svg-backend--format-programs
  (list (lambda () latex-to-svg-backend-latex-program))
  "Functions returning the TeX programs that dump a `.fmt' file.
Each `.fmt' file is keyed by its program (see
`latex-to-svg-backend--format-key'), so
`latex-to-svg-backend-invalidate-format' deletes one per program.  An
engine that dumps with another program adds a function here; one that
returns nil stands for `latex-to-svg-backend-latex-program'.")

;;;; Capability

(defun latex-to-svg-backend--latex-tools-available-p ()
  "Return non-nil when the LaTeX-to-SVG toolchain is on the variable `exec-path'."
  (and (executable-find latex-to-svg-backend-latex-program)
       (executable-find latex-to-svg-backend-dvisvgm-program)))

;;;; Preamble

(defun latex-to-svg-backend--preamble ()
  "Return the current buffer's LaTeX preamble: the base plus appended packages.
This is the exact text embedded before `\\begin{document}' in a full
compile, and the text dumped into the precompiled `.fmt' file.  When
`latex-to-svg-backend-line-width' is set, a `\\sa@width' override is
appended so the `varwidth' box uses that width (see that variable).

When `latex-to-svg-backend-preamble' or
`latex-to-svg-backend-appended-preamble' has a buffer-local value, the
text starts with the line of `latex-to-svg-backend--input-path', so a
relative `\\input' in it finds its file: the dump runs in the cache.
The directory is then part of the text, so two projects with the same
`\\input{macros.tex}' get two `.fmt' files; without a buffer-local value
everyone shares one."
  (concat
   (when (or (local-variable-p 'latex-to-svg-backend-preamble)
             (local-variable-p 'latex-to-svg-backend-appended-preamble))
     (latex-to-svg-backend--input-path))
   latex-to-svg-backend-preamble
   (unless (string-empty-p latex-to-svg-backend-appended-preamble)
     (concat "\n" latex-to-svg-backend-appended-preamble))
   ;; Override `standalone's varwidth width (`\sa@width', default
   ;; `\linewidth').  Placed last so it wins over the class default.
   (when latex-to-svg-backend-line-width
     (format "\n\\makeatletter\\def\\sa@width{%s}\\makeatother"
             latex-to-svg-backend-line-width))))

(defun latex-to-svg-backend--input-directory ()
  "Return the directory `\\input' searches for the current buffer, or nil.
That is the project root (`project-root'), else `default-directory'.
The directory is written into TeX code (see
`latex-to-svg-backend--input-path'), so a directory whose name
holds a character TeX reads as code is refused, as is a remote one
\(the compile runs locally): the refusal is reported once and nil
returned, and no `\\input@path' is written."
  (let ((dir (file-name-as-directory
              (expand-file-name
               (if-let* ((project (project-current)))
                   (project-root project)
                 default-directory)))))
    (cond
     ;; LaTeX runs on this machine and cannot open a file on another.
     ((file-remote-p dir)
      (latex-to-svg-backend--warn-once
       "searching a remote directory for \\input files"
       (list 'error (format "%s is remote, but LaTeX runs locally" dir))))
     ;; The OS allows characters in a path that TeX reads as code: `%'
     ;; starts a comment, `#' a parameter, `\' a command, braces a group,
     ;; and `~' is a space.
     ((string-match-p "[\\{}%#~]" dir)
      (latex-to-svg-backend--warn-once
       "searching for \\input files"
       (list 'error (format "%s holds one of \\ { } %% # ~" dir))))
     (t dir))))

(defun latex-to-svg-backend--input-path ()
  "Return the line pointing `\\input@path' at the current buffer's project.
The directory is `latex-to-svg-backend--input-directory'; the line is
nil when that refuses it."
  (when-let* ((dir (latex-to-svg-backend--input-directory)))
    (format "\\makeatletter\\def\\input@path{{%s}}\\makeatother\n" dir)))

(defun latex-to-svg-backend--not-precompiled ()
  "Return the current buffer's text for after the preamble, or \"\".
That is `latex-to-svg-backend-preamble-not-precompiled', preceded by
the line of `latex-to-svg-backend--input-path', or \"\" when the option
is empty."
  (if (string-empty-p latex-to-svg-backend-preamble-not-precompiled)
      ""
    (concat (latex-to-svg-backend--input-path)
            latex-to-svg-backend-preamble-not-precompiled)))

(defun latex-to-svg-backend--latex-inputs ()
  "Return what the LaTeX engine reads from the current buffer, as a plist.
That is `(:preamble PREAMBLE :not-precompiled TEXT)', the texts of
`latex-to-svg-backend--preamble' and
`latex-to-svg-backend--not-precompiled'.  A request reads them once,
in the buffer that makes it, and passes them on: a compile's retry and
fallback start from the process sentinel, where the current buffer is
another."
  (list :preamble (latex-to-svg-backend--preamble)
        :not-precompiled (latex-to-svg-backend--not-precompiled)))

(defun latex-to-svg-backend--latex-cache-salt (inputs)
  "Return what `latex-to-svg-backend--cache-key' folds in for LaTeX.
INPUTS is as for `latex-to-svg-backend--latex-inputs'.  That is the
preamble, then the not-precompiled text when it is not empty, so an
empty one leaves the key as it was before that option existed."
  (let ((preamble (plist-get inputs :preamble))
        (not-precompiled (plist-get inputs :not-precompiled)))
    (if (string-empty-p not-precompiled)
        preamble
      (concat preamble "\n" not-precompiled))))

;;;; Preamble precompilation (.fmt)

;; Speedup: dump the preamble (class + packages) to a LaTeX `.fmt' file once,
;; with TeX's `\dump', then load it from every equation compile with a `%&'
;; first line instead of re-reading and re-loading amsmath/xcolor/... each
;; time.  Entirely optional: on any hiccup the backend falls back to
;; embedding the full preamble in each equation, so a `.fmt' file is a pure
;; performance optimization, never a correctness dependency.

(defun latex-to-svg-backend--latex-binary (&optional program)
  "Return the path to the LaTeX executable, or nil.
PROGRAM is the TeX program, by default `latex-to-svg-backend-latex-program'.
Honours an absolute PROGRAM, else resolves the command name on variable
`exec-path'.  Used for the freshness check of the `.fmt' file."
  (let ((prog (car (split-string (or program latex-to-svg-backend-latex-program)))))
    (if (file-name-absolute-p prog)
        (and (file-executable-p prog) prog)
      (executable-find prog))))

(defun latex-to-svg-backend--latex-format-name (&optional program)
  "Return the name of the LaTeX `.fmt' file the dump starts from.
That is the `&NAME' of the `-ini' run, e.g. \"latex\" for `latex.fmt':
the name of PROGRAM, by default `latex-to-svg-backend-latex-program'."
  (file-name-nondirectory
   (car (split-string (or program latex-to-svg-backend-latex-program)))))

(defun latex-to-svg-backend--format-key (preamble &optional program)
  "Return the cache key naming the precompiled `.fmt' file of PREAMBLE.
PREAMBLE is the text of `latex-to-svg-backend--preamble'.  Folds in
PREAMBLE and the TeX PROGRAM that dumps it, by default
`latex-to-svg-backend-latex-program', so any change to either yields a
distinct `.fmt' file (and a dump on the next render)."
  (secure-hash 'sha1 (format "%s\0%s"
                             preamble
                             (or program latex-to-svg-backend-latex-program))))

(defun latex-to-svg-backend--fmt-dir ()
  "Return the subdirectory holding precompiled `.fmt' files, creating it."
  (latex-to-svg-backend--subdir "fmt"))

(defun latex-to-svg-backend--format-file (fkey)
  "Return the path of the precompiled `.fmt' file for FKEY."
  (expand-file-name (concat fkey ".fmt") (latex-to-svg-backend--fmt-dir)))

(defun latex-to-svg-backend--format-stamp-file (format-file)
  "Return the path of the stamp (`.eld') of FORMAT-FILE.
The stamp names the LaTeX binary that dumped FORMAT-FILE (see
`latex-to-svg-backend--binary-stamp')."
  (concat (file-name-sans-extension format-file) ".eld"))

(defun latex-to-svg-backend--binary-stamp (binary)
  "Return the plist identifying the LaTeX BINARY, for a `.fmt' stamp.
That is `(:binary TRUENAME :mtime MTIME)': the file BINARY resolves to
and its modification time.  A TeX Live release installs its binaries
under a directory named after its year, so an upgrade changes the
truename; another TeX first on variable `exec-path' changes either."
  (let ((truename (file-truename binary)))
    (list :binary truename
          :mtime (file-attribute-modification-time
                  (file-attributes truename)))))

(defun latex-to-svg-backend--format-fresh-p (format-file binary)
  "Return non-nil when FORMAT-FILE was dumped by the LaTeX BINARY.
That is when its stamp matches `latex-to-svg-backend--binary-stamp' for
BINARY.  A `.fmt' file with no stamp is stale, so one dumped before
stamps existed is dumped again once.  So is one with an unreadable
stamp, which is reported once: the dump writes a new stamp."
  (let ((file (latex-to-svg-backend--format-stamp-file format-file)))
    (when (file-readable-p file)
      (when-let* ((stamp (condition-case err
                             (with-temp-buffer
                               (insert-file-contents file)
                               (read (current-buffer)))
                           ((end-of-file invalid-read-syntax file-error)
                            (latex-to-svg-backend--warn-once
                             "reading a .fmt stamp" err))))
                  ((consp stamp))
                  (mtime (plist-get stamp :mtime))
                  (current (latex-to-svg-backend--binary-stamp binary)))
        (and (equal (plist-get stamp :binary) (plist-get current :binary))
             (plist-get current :mtime)
             (time-equal-p mtime (plist-get current :mtime)))))))

(defun latex-to-svg-backend--write-format-stamp (format-file binary)
  "Record that the LaTeX BINARY dumped FORMAT-FILE, in its stamp.
A stamp that cannot be written is reported once; the `.fmt' file still
serves this session and is dumped again in the next."
  (condition-case err
      (with-temp-file (latex-to-svg-backend--format-stamp-file format-file)
        (prin1 (latex-to-svg-backend--binary-stamp binary) (current-buffer)))
    (file-error
     (latex-to-svg-backend--warn-once "writing a .fmt stamp" err))))

(defun latex-to-svg-backend--touch-format (format-file)
  "Bump FORMAT-FILE's modification time and return FORMAT-FILE, or nil.
`latex-to-svg-backend-gc' deletes a `.fmt' file whose mtime is older
than `latex-to-svg-backend-cache-max-age', so this runs on every compile
that loads it: a session that runs for longer must not lose the `.fmt'
file it uses.  Nil means another session collected FORMAT-FILE a
moment ago; the caller then compiles with the full preamble.  Any other
refusal by the filesystem is reported once and FORMAT-FILE returned:
the `.fmt' file works, it only ages out."
  (condition-case err
      (progn (set-file-times format-file) format-file)
    (file-missing nil)
    (file-error
     (latex-to-svg-backend--warn-once "recording .fmt use" err)
     format-file)))

(defun latex-to-svg-backend--build-format (fkey preamble &optional program)
  "Dump PREAMBLE to the `.fmt' file for FKEY, synchronously.
Return the `.fmt' path on success, nil on failure.  Writes PREAMBLE
followed by TeX's `\\dump' to a scratch `.tex' in the `fmt/'
subdirectory and runs the TeX PROGRAM on it in `-ini' mode (by default
`latex-to-svg-backend-latex-program'), which writes
`<cache>/fmt/FKEY.fmt'.  The build log is in
the `*latex-to-svg-backend-precompile-log*' buffer for inspection.

A preamble that will not dump exits non-zero and yields nil (the caller
falls back to a full compile, which reports the real LaTeX error).  A
TeX program that is not found signals `file-missing', which
`latex-to-svg-backend--ensure-format' handles; one that is found but
cannot be started is reported once."
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
        (insert preamble "\n\\dump\n")))
    (message "latex-to-svg-backend: precompiling LaTeX preamble...")
    (let ((rv (unwind-protect
                  (condition-case err
                      (call-process (or program latex-to-svg-backend-latex-program)
                                    nil buffer nil
                                    (concat "-output-directory=" dir)
                                    "-ini"
                                    (concat "-jobname=" fkey)
                                    (concat "&" (latex-to-svg-backend--latex-format-name
                                                 program))
                                    pre-tex)
                    (file-missing (signal (car err) (cdr err)))
                    ;; Found but cannot be started.  Report it once; the
                    ;; caller falls back to a full compile, which reports
                    ;; its own failure.
                    (file-error
                     (latex-to-svg-backend--warn-once
                      "dumping the LaTeX preamble" err)))
                (delete-file pre-tex))))
      (if (and (eql rv 0) (file-exists-p fmt))
          (progn
            (delete-file log)
            (when-let* ((binary (latex-to-svg-backend--latex-binary program)))
              (latex-to-svg-backend--write-format-stamp fmt binary))
            fmt)
        (delete-file fmt)
        nil))))

(defun latex-to-svg-backend--ensure-format (preamble &optional program)
  "Return the path of a fresh precompiled `.fmt' file of PREAMBLE, or nil.
PREAMBLE is the text of `latex-to-svg-backend--preamble'; PROGRAM is
the TeX program that dumps and loads it, by default
`latex-to-svg-backend-latex-program'.  Dumps the
`.fmt' file on first use (synchronously, once per session per
preamble) and caches it on disk.  Rebuilds it when its stamp names
another LaTeX binary (see `latex-to-svg-backend--format-fresh-p'), as
after a TeX toolchain upgrade, where `latex' would otherwise refuse
the `.fmt' file on every compile.  Bumps the mtime of the `.fmt' file it
returns (see `latex-to-svg-backend--touch-format').  Returns nil — so
the caller uses a full compile — when precompilation is off, the dump
fails, or the `.fmt' file has been blocklisted after an earlier
failure.  When PROGRAM is not found, it returns nil without
blocklisting, so the compile reports the missing program and the dump
runs once PROGRAM is installed."
  (when latex-to-svg-backend-precompile
    (let ((fkey (latex-to-svg-backend--format-key preamble program)))
      (unless (gethash fkey latex-to-svg-backend--format-blocklist)
        (let ((fmt (latex-to-svg-backend--format-file fkey))
              (latex-bin (latex-to-svg-backend--latex-binary program)))
          (cond
           ;; Verified fresh already this session.
           ((and (gethash fkey latex-to-svg-backend--format-checked)
                 (file-exists-p fmt))
            (latex-to-svg-backend--touch-format fmt))
           ;; On disk and dumped by this binary -> trust it.
           ((and (file-exists-p fmt)
                 (or (null latex-bin)
                     (latex-to-svg-backend--format-fresh-p fmt latex-bin)))
            (puthash fkey t latex-to-svg-backend--format-checked)
            (latex-to-svg-backend--touch-format fmt))
           ;; Missing or stale -> (re)build.
           (t
            (delete-file fmt)
            (delete-file (latex-to-svg-backend--format-stamp-file fmt))
            (condition-case nil
                (if-let* ((built (latex-to-svg-backend--build-format
                                  fkey preamble program)))
                    (progn
                      (puthash fkey t latex-to-svg-backend--format-checked)
                      built)
                  ;; The dump failed.  Give up on this preamble for the
                  ;; session: retrying would run a synchronous `latex -ini'
                  ;; for every equation, and a preamble that will not dump
                  ;; does not start dumping on the next attempt.
                  (latex-to-svg-backend--block-format fmt)
                  nil)
              (file-missing nil)))))))))

(defun latex-to-svg-backend--block-format (format-file)
  "Abandon FORMAT-FILE and skip precompilation for its preamble this session.
Deletes the `.fmt' file (if any) and blocklists its key, so
`--ensure-format' returns nil for this preamble for the rest of the
session and the backend falls back to full compiles.  Warns once — one
warning per preamble, since the blocklist short-circuits every later
call.

Called from the two ways precompilation can fail: the dump itself failed
\(see `latex-to-svg-backend--build-format'; the log stays in the
`*latex-to-svg-backend-precompile-log*' buffer), or the dump succeeded but a
compile that loaded it failed.  In the latter case the same equation is
about to be retried with the full inline preamble, so a genuinely broken
equation is not mistaken for a broken `.fmt' file."
  (let ((fkey (file-name-base format-file)))
    (puthash fkey t latex-to-svg-backend--format-blocklist)
    (remhash fkey latex-to-svg-backend--format-checked)
    (delete-file format-file)
    (delete-file (latex-to-svg-backend--format-stamp-file format-file))
    (display-warning
     'latex-to-svg-backend
     "Precompiled LaTeX preamble failed; falling back to full compiles."
     :warning)))

;;;###autoload
(defun latex-to-svg-backend-flush-format ()
  "Delete all precompiled `.fmt' files and forget them.

Removes every `.fmt' file in the cache `fmt/' subdirectory, with its
stamp, and clears this session's freshness and blocklist tracking, so
the next render dumps a fresh `.fmt' file from the current preamble.
An escape hatch for a stale `.fmt' file the automatic freshness check
missed — normally a TeX toolchain upgrade is handled on its own (the
stamp names another binary), so this is rarely needed."
  (interactive)
  (clrhash latex-to-svg-backend--format-checked)
  (clrhash latex-to-svg-backend--format-blocklist)
  (let ((dir (expand-file-name "fmt" (latex-to-svg-backend--cache-dir))))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\.\\(?:fmt\\|eld\\)\\'"))
        (delete-file f)))))

;;;###autoload
(defun latex-to-svg-backend-invalidate-format ()
  "Delete the precompiled `.fmt' file of the current buffer's preamble.

A `.fmt' file holds the files its preamble loads as they were when it
was dumped, and nothing detects an edit to them, so after editing one
\(say the `macros.tex' of an `\\input{macros.tex}') call this, then
compile the equations again.  Deletes the `.fmt' file with its stamp
and forgets this session's freshness check and blocklist entry for it,
so the next compile dumps it again: that also retries a preamble whose
dump failed, after the missing package is installed.  Other preambles'
`.fmt' files stay (see `latex-to-svg-backend-flush-format')."
  (interactive)
  (let ((preamble (latex-to-svg-backend--preamble)))
    (dolist (program (delete-dups
                      (mapcar #'funcall latex-to-svg-backend--format-programs)))
      (let* ((fkey (latex-to-svg-backend--format-key preamble program))
             (fmt (latex-to-svg-backend--format-file fkey)))
        (remhash fkey latex-to-svg-backend--format-checked)
        (remhash fkey latex-to-svg-backend--format-blocklist)
        (delete-file fmt)
        (delete-file (latex-to-svg-backend--format-stamp-file fmt))))))

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

(defun latex-to-svg-backend--latex-formula-error-p (dir)
  "Return non-nil when the log in scratch DIR shows LaTeX rejected the input.
That is a `! ' error line in `equation.log', such as \"! Undefined control
sequence.\" or \"! LaTeX Error: File `siunitx.sty' not found.\": compiling
the same document again fails the same way.  \"! I can't write on file\"
is a disk problem, not the input's, and does not count."
  (let ((log (expand-file-name "equation.log" dir)))
    (and (file-readable-p log)
         (with-temp-buffer
           (let ((coding-system-for-read 'raw-text))
             (insert-file-contents log))
           (goto-char (point-min))
           (and (re-search-forward "^! " nil t)
                (not (looking-at-p "I can't write on file")))))))

(defconst latex-to-svg-backend--latex-baseline-mark
  (concat "\\ifhmode\\ifnum\\prevgraf=0 \\special{dvisvgm:raw "
          (format latex-to-svg-backend--baseline-comment "{?y}")
          "}\\fi\\fi\n")
  "Text after the equation that marks the baseline of its line.
dvisvgm writes the special's text into the SVG with `{?y}' replaced by
the current vertical position, in the SVG's coordinates: after inline
math that is the baseline of its line.  After a display TeX has resumed
the paragraph on a new line, below the equation, and counts the display
as three lines in `\\prevgraf', so the mark is written only while
`\\prevgraf' is 0, before any display.  A display equation therefore
has no baseline, and is centred on its line (see
`latex-to-svg-backend--ascent').  Inline math sits on the baseline of
the last line of its paragraph, as text does.")

(defconst latex-to-svg-backend--latex-x-height-tex
  (concat "\\dimen0=\\fontdimen5\\textfont1 "
          "\\ifdim\\dimen0=0pt \\dimen0=\\fontdimen5\\font\\fi "
          "\\dimen0=\\dimexpr\\dimen0*7200/7227\\relax ")
  "TeX that sets `\\dimen0' to the x-height of the equation's font, in bp.
That is `\\fontdimen5' of the math italic font at text size, the font
the variables of an equation are set in, or of the current font when
the body set no math.  It is converted to big points, the unit of
dvisvgm's and pdftocairo's SVGs.  Run inside a group.")

(defconst latex-to-svg-backend--latex-x-height-mark
  (concat "\\begingroup" latex-to-svg-backend--latex-x-height-tex
          "\\special{dvisvgm:raw "
          (format latex-to-svg-backend--x-height-comment "\\the\\dimen0")
          "}\\endgroup\n")
  "Text after the equation that writes its font's x-height into the SVG.
See `latex-to-svg-backend--x-height-comment'.  Unlike the baseline, it
is written for display equations too: every image is sized by it.")

(defun latex-to-svg-backend--latex-toolchain ()
  "Return the toolchain of the LaTeX engine: `latex', then `dvisvgm'.
A toolchain is the plist `latex-to-svg-backend--compile' runs:

  :engine   the engine, for the failure report (see
            `latex-to-svg-backend--compile-failed');
  :program  the TeX program, nil meaning `latex-to-svg-backend-latex-program';
  :output   the file the TeX program writes in the scratch directory;
  :prefix   text written after `\\begin{document}', before the equation;
  :suffix   text written after the equation, before `\\end{document}';
  :convert  a function of the scratch directory, the TeX output file
            and the cache SVG, returning the stages that make the SVG
            (see `latex-to-svg-backend--run-process-chain');
  :store    nil, or a function of the scratch directory and the cache
            SVG run after the stages, that returns non-nil once the
            cache SVG is written.

The LaTeX engine's `dvisvgm' writes the cache SVG itself.  It runs at
scale 1: the SVG is vector (glyphs are outline paths via --no-fonts),
so the scale doesn't affect quality, and the displayed size is set
later by `latex-to-svg-backend-display-scale'.  `--currentcolor'
rewrites the default ink to the `currentColor' token, so the file is
color-independent (tinted at display time).  The suffix has dvisvgm
write the baseline of an inline equation into the SVG
\(`latex-to-svg-backend--latex-baseline-mark') and the x-height of the
equation's font (`latex-to-svg-backend--latex-x-height-mark')."
  (list :engine 'latex
        :program nil
        :output "equation.dvi"
        :prefix ""
        :suffix (concat latex-to-svg-backend--latex-baseline-mark
                        latex-to-svg-backend--latex-x-height-mark)
        :convert (lambda (_dir dvi svg)
                   (list
                    (list 'dvisvgm
                          (list latex-to-svg-backend-dvisvgm-program
                                "--no-fonts"
                                "--exact-bbox"
                                "--currentcolor"
                                "--scale=1"
                                "-o"
                                svg
                                dvi)
                          svg)))
        :store nil))

(defun latex-to-svg-backend--compile
    (key latex &optional metadata inputs no-format toolchain)
  "Asynchronously compile LATEX to the color-independent cache SVG for KEY.
METADATA, when non-nil, is stored as the INITIAL value in KEY's `.eld'
sidecar alongside the FINAL captured from the log (see
`latex-to-svg-backend--write-metadata').  INPUTS is the plist of
`latex-to-svg-backend--latex-inputs', nil meaning the current buffer's;
the retry below passes it on, since it runs from the process sentinel,
where the current buffer is another.  TOOLCHAIN is the plist of
`latex-to-svg-backend--latex-toolchain', nil meaning that one; another
engine that compiles with LaTeX passes its own.

LATEX is placed verbatim in the document body (the caller supplies
valid body LaTeX and chooses inline vs display via delimiters).
Writes a standalone LaTeX document, runs the TeX program and then the
TOOLCHAIN's stages in a scratch directory, and on success caches the
SVG and notifies every callback queued for KEY (see
`latex-to-svg-backend--enqueue').  The scratch directory is removed
when the process exits.

The preamble is loaded from a precompiled `.fmt' file when one is
available (see `latex-to-svg-backend-precompile'), via a `%&' first line;
otherwise the full preamble is embedded in the document.  On failure, if
a `.fmt' file was loaded it may be the culprit: it is abandoned (see
`latex-to-svg-backend--block-format') and the same equation is retried once with
the full inline preamble.  Only when a full-preamble compile fails is
the failure handled (see `latex-to-svg-backend--compile-failed'): the log
is saved, and when the TeX program stopped on an error in the document
\(see `latex-to-svg-backend--latex-formula-error-p') the failure is
recorded.  NO-FORMAT forces that inline path (it is set on the retry).

No color is baked in: the equation's default ink becomes the literal
`currentColor', so the SVG is color-independent and is tinted to the
caller's `:color' at display time (`latex-to-svg-backend--load-svg-image').
A theme change therefore re-tints from cache without recompiling."
  (let* ((toolchain (or toolchain (latex-to-svg-backend--latex-toolchain)))
         (program (or (plist-get toolchain :program)
                      latex-to-svg-backend-latex-program))
         (store (plist-get toolchain :store))
         (dir (make-temp-file "latex-to-svg-backend" t))
         (tex (expand-file-name "equation.tex" dir))
         (output (expand-file-name (plist-get toolchain :output) dir))
         (svg (latex-to-svg-backend--svg-file key))
         (inputs (or inputs (latex-to-svg-backend--latex-inputs)))
         (preamble (plist-get inputs :preamble))
         (not-precompiled (plist-get inputs :not-precompiled))
         (format-file (and (not no-format)
                           (latex-to-svg-backend--ensure-format
                            preamble (plist-get toolchain :program))))
         (body (concat "\\begin{document}\n"
                       (plist-get toolchain :prefix)
                       ;; LATEX is inserted verbatim: it already carries
                       ;; its own math delimiters / environment (chosen by
                       ;; the front-end), which also decide inline vs
                       ;; display sizing.
                       ;; A newline first, so that a `%' comment at the end
                       ;; of LATEX does not hide the suffix.
                       latex "\n"
                       (or (plist-get toolchain :suffix) "")
                       "\\end{document}\n"))
         (cleanup (lambda () (delete-directory dir t)))
         (output-buffer (generate-new-buffer
                         (format " *latex-to-svg-backend-%s*" key))))
    ;; Pin UTF-8 on write.  LaTeX has read UTF-8 by default since its
    ;; 2018-04-01 release, so the encoding belongs here and not in an
    ;; `inputenc' line: adding a package to the preamble would rehash
    ;; `--cache-key' and the `.fmt' key, discarding every cached SVG and
    ;; `.fmt' file for every user, to declare what the backend already writes.
    ;; Unpinned, an equation carrying a character the user's default coding
    ;; system cannot encode (an alpha under a Latin-1 language environment,
    ;; say) makes `write-region' *prompt* -- fatal in a background compile,
    ;; and no `.tex' is written at all.  Same hazard the log copy guards
    ;; (`--compile-failed'), but this file carries the user's own math.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file tex
        (insert (if format-file
                    ;; Load the precompiled preamble: the `%&' line must be
                    ;; first, and names the `.fmt' file by absolute path
                    ;; without its `.fmt' extension.  The class + packages
                    ;; are already in the `.fmt' file, so they are not
                    ;; written here.
                    (concat "%& " (file-name-sans-extension format-file) "\n")
                  (concat preamble "\n"))
                (if (string-empty-p not-precompiled)
                    ""
                  (concat not-precompiled "\n"))
                body)))
    (latex-to-svg-backend--run-process-chain
     dir output-buffer
     (cons (list 'latex
                 (list program
                       "-interaction=nonstopmode"
                       "-halt-on-error"
                       tex)
                 output)
           (funcall (plist-get toolchain :convert) dir output svg))
     (lambda (success &optional exit)
       (let* ((stored
               (and success
                    (or (null store)
                        (condition-case err
                            (or (funcall store dir svg)
                                (progn
                                  (latex-to-svg-backend--append-process-log
                                   output-buffer
                                   "[store] output has no <svg> element")
                                  nil))
                          (file-error
                           (latex-to-svg-backend--append-process-log
                            output-buffer
                            (format "[store] storing the SVG failed: %s"
                                    (error-message-string err)))
                           nil)))))
              ;; A program that is not found fails with any preamble.
              (retry-format (and (not stored) format-file
                                 (not (stringp (cdr exit))))))
         (unwind-protect
             (cond
              (stored
               ;; Capture compile metadata before DIR is cleaned up.
               (latex-to-svg-backend--write-metadata key dir metadata)
               (latex-to-svg-backend--notify-pending key))
              ;; A failed compile that loaded a `.fmt' file is retried once
              ;; with the full inline preamble; keep the pending callback
              ;; queue intact.
              (retry-format
               (latex-to-svg-backend--block-format format-file))
              ;; Genuine failure (full preamble): persist diagnostics.
              (t
               (latex-to-svg-backend--compile-failed
                key latex dir
                (latex-to-svg-backend--process-output output-buffer)
                (plist-get toolchain :engine)
                (and (eq (car exit) 'latex)
                     (latex-to-svg-backend--latex-formula-error-p dir))
                exit)))
           (unless retry-format
             (latex-to-svg-backend--compile-done key))
           (when (buffer-live-p output-buffer)
             (kill-buffer output-buffer))
           (funcall cleanup))
         ;; The retry keeps the slot of this compile.
         (when retry-format
           (latex-to-svg-backend--start-compile
            key (lambda ()
                  (latex-to-svg-backend--compile
                   key latex metadata inputs t toolchain)))))))))

(provide 'latex-to-svg-backend-latex)

;;; latex-to-svg-backend-latex.el ends here
