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

;; Before the first alias on purpose: once an alias exists, setting it
;; cannot be told from setting its option.
(defconst latex-to-svg-backend--obsolete-aliases-set
  (seq-filter (lambda (alias)
                (or (boundp alias) (get alias 'saved-value)))
              '(latex-to-svg-backend-preamble
                latex-to-svg-backend-appended-preamble
                latex-to-svg-backend-preamble-macros
                latex-to-svg-backend-preamble-macro-files))
  "The obsolete aliases the user set before this file loaded.
An alias bound, or saved by Customize, before this file defines it was
set by the user's init file.  Once the alias exists, setting it cannot
be told from setting its option: both are one variable.")

(define-obsolete-variable-alias 'latex-to-svg-backend-preamble
  'latex-to-svg-backend-preamble-base "0.17.0")

(defcustom latex-to-svg-backend-preamble-base
  "\\documentclass[varwidth,border=2pt]{standalone}
\\usepackage{amsmath}
\\usepackage{amssymb}
\\usepackage{xcolor}"
  "LaTeX preamble base (the document class and base packages).
`latex-to-svg-backend-preamble-packages' is appended to it.  To add
packages or macro files, set
`latex-to-svg-backend-preamble-packages' and leave this option alone.
Set this option only to change the class options or to remove a base
package that conflicts with one you add.

The `standalone' class crops the page tightly to the equation, so
no `preview' package is required.  dvisvgm's `--exact-bbox' then crops
to the actual ink.  A replacement must keep:
- the `varwidth' option, which lets the verbatim body use *display*
  math (`\\=\\[...\\=\\]', `equation', `align'): plain `standalone'
  typesets its body as a single horizontal box and errors with
  \"Missing $ inserted\" on display math;
- `xcolor', for the texres engine: it writes `\\color[RGB]{1,2,3}'
  before the equation and turns that color into `currentColor', so a
  formula's own `\\color{black}' stays black; without `xcolor', black
  becomes `currentColor'."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(define-obsolete-variable-alias 'latex-to-svg-backend-appended-preamble
  'latex-to-svg-backend-preamble-packages "0.16.0")

(defcustom latex-to-svg-backend-preamble-packages ""
  "LaTeX code for packages, appended to `latex-to-svg-backend-preamble-base'.
For the extra packages of a project, including your own `.sty' files:
`\\usepackage{physics}', say, and optionally an `\\input' of your macro
files, `\\input{macros.tex}'.  List the files it loads in
`latex-to-svg-backend-preamble-package-files'.  The text is dumped into
the `.fmt' file (see `latex-to-svg-backend-precompile') and read once.
Changing this text, or a file listed in
`latex-to-svg-backend-preamble-package-files', dumps the whole `.fmt'
file again.

The value is folded into the cache key, so changing it re-renders.
Set in a project's `.dir-locals.el', it is dumped into a `.fmt' file of
that project.  `\\input' looks for the file in the project root
\(`project-root'), or in `default-directory' outside a project, so
`\\input{paper/macros.tex}' names a file below the root."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(define-obsolete-variable-alias 'latex-to-svg-backend-preamble-macros
  'latex-to-svg-backend-preamble-not-precompiled "0.18.0")

(make-obsolete-variable 'latex-to-svg-backend-preamble-macros
                        "put macro files in \
`latex-to-svg-backend-preamble-packages' and list them in \
`latex-to-svg-backend-preamble-package-files'"
                        "0.18.0")

(defcustom latex-to-svg-backend-preamble-not-precompiled ""
  "LaTeX code written after the preamble at every compile, not dumped.
For a package that cannot be dumped into the `.fmt' file (see
`latex-to-svg-backend-precompile'): one that opens a file or reads
`\\jobname' when it loads, say.  Everything else belongs in
`latex-to-svg-backend-preamble-packages', macro files included, where
it is read once.

`\\input' looks for its files as for
`latex-to-svg-backend-preamble-packages'.  The value and the directory
are folded into the cache key, and so is the modification time of each
file listed in `latex-to-svg-backend-preamble-not-precompiled-files'.
The RaTeX engine ignores this option."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defun latex-to-svg-backend--file-names-p (value)
  "Return non-nil when VALUE is a list of file names (strings)."
  (and (listp value) (seq-every-p #'stringp value)))

(defcustom latex-to-svg-backend-preamble-package-files nil
  "Files `latex-to-svg-backend-preamble-packages' loads.
Such as your own `.sty' files and macro files, `macros.tex', say.
Names are relative to the project root (`project-root'), or to
`default-directory' outside a project, or absolute.  The modification
time of each is folded into the cache key and recorded in the stamp of
the `.fmt' file, so an edit of one compiles the equations again, and
the next compile dumps the `.fmt' file again.  A file that is not
listed is not followed: after editing it,
`latex-to-svg-backend-invalidate-format' dumps the `.fmt' file again
and `latex-to-svg-backend-invalidate' compiles an equation again."
  :type '(repeat file)
  ;; Inert: only its files' modification times are read.
  :safe #'latex-to-svg-backend--file-names-p
  :group 'latex-to-svg-backend-latex)

(define-obsolete-variable-alias 'latex-to-svg-backend-preamble-macro-files
  'latex-to-svg-backend-preamble-not-precompiled-files "0.18.0")

(defcustom latex-to-svg-backend-preamble-not-precompiled-files nil
  "Files `latex-to-svg-backend-preamble-not-precompiled' loads.
Names are relative to the project root (`project-root'), or to
`default-directory' outside a project, or absolute.  The modification
time of each is folded into the cache key, so an edit of one compiles
the equations again.  The `.fmt' file does not hold these files, so an
edit dumps nothing again.  A file that is not listed is not followed:
after editing it, `latex-to-svg-backend-invalidate' compiles an
equation again."
  :type '(repeat file)
  ;; Inert: only its files' modification times are read.
  :safe #'latex-to-svg-backend--file-names-p
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

The class and packages in `latex-to-svg-backend-preamble-base' /
`latex-to-svg-backend-preamble-packages' are dumped once, with TeX's
`\\dump', to a `.fmt' file keyed by the preamble text; every equation
compile then loads it with a `%&' first line instead of re-reading the
preamble, which speeds each compile up noticeably.

When the dump fails, the failure is reported with its log, and no
equation is compiled with this preamble until it is dumped again: after
a change to the preamble, to a file listed in
`latex-to-svg-backend-preamble-package-files', or to the TeX
installation.  A `.fmt' file dumped by
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
;; program).  `--format-stamps' holds the stamp of each `.fmt' file, read
;; from disk once per session, so each compile checks the files it names
;; without reading it.
(defvar latex-to-svg-backend--format-stamps (make-hash-table :test 'equal)
  "Map of `.fmt' key to its stamp, read once per session.
See `latex-to-svg-backend--format-stamp'.")

(defvar latex-to-svg-backend--format-programs
  (list (lambda () latex-to-svg-backend-latex-program))
  "Functions returning the TeX programs that dump a `.fmt' file.
A program is as for `latex-to-svg-backend--tex-command'.
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
  "Return the current buffer's LaTeX preamble: the base plus its packages.
This is the exact text embedded before `\\begin{document}' in a full
compile, and the text dumped into the precompiled `.fmt' file.  When
`latex-to-svg-backend-line-width' is set, a `\\sa@width' override is
appended so the `varwidth' box uses that width (see that variable).

When `latex-to-svg-backend-preamble-base' or
`latex-to-svg-backend-preamble-packages' has a buffer-local value, the
text starts with the line of `latex-to-svg-backend--input-path', so a
relative `\\input' in it finds its file: the dump runs in the cache.
The directory is then part of the text, so two projects with the same
`\\input{macros.tex}' get two `.fmt' files; without a buffer-local value
everyone shares one."
  (concat
   (when (or (local-variable-p 'latex-to-svg-backend-preamble-base)
             (local-variable-p 'latex-to-svg-backend-preamble-packages))
     (latex-to-svg-backend--input-path))
   latex-to-svg-backend-preamble-base
   (unless (string-empty-p latex-to-svg-backend-preamble-packages)
     (concat "\n" latex-to-svg-backend-preamble-packages))
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
\(the compile runs locally): the refusal is reported once per buffer
\(see `latex-to-svg-backend--warn') and nil returned, and no
`\\input@path' is written."
  (let ((dir (file-name-as-directory
              (expand-file-name
               (if-let* ((project (project-current)))
                   (project-root project)
                 default-directory)))))
    (cond
     ;; LaTeX runs on this machine and cannot open a file on another.
     ((file-remote-p dir)
      (latex-to-svg-backend--warn
       "remote input directory"
       (format "The project directory %s is remote, but LaTeX runs on this \
machine, so `\\input' does not search it.
To use the files of the project, open it from a local directory." dir))
      nil)
     ;; The OS allows characters in a path that TeX reads as code: `%'
     ;; starts a comment, `#' a parameter, `\' a command, braces a group,
     ;; and `~' is a space.
     ((string-match-p "[\\{}%#~]" dir)
      (latex-to-svg-backend--warn
       "input directory holds TeX code"
       (format "The project directory %s holds one of \\ { } %% # ~, \
which TeX reads as code, so `\\input' does not search it.
To use the files of the project, rename the directory." dir))
      nil)
     (t dir))))

(defun latex-to-svg-backend--input-path ()
  "Return the line pointing `\\input@path' at the current buffer's project.
The directory is `latex-to-svg-backend--input-directory'; the line is
nil when that refuses it."
  (when-let* ((dir (latex-to-svg-backend--input-directory)))
    (format "\\makeatletter\\def\\input@path{{%s}}\\makeatother\n" dir)))

(defun latex-to-svg-backend--macros ()
  "Return the current buffer's text for after the preamble, or \"\".
That is `latex-to-svg-backend-preamble-not-precompiled', preceded by
the line of `latex-to-svg-backend--input-path', or \"\" when the option
is empty."
  (if (string-empty-p latex-to-svg-backend-preamble-not-precompiled)
      ""
    (concat (latex-to-svg-backend--input-path)
            latex-to-svg-backend-preamble-not-precompiled)))

(defun latex-to-svg-backend--preamble-file-stamp (file)
  "Return (FILE . MTIME), MTIME nil when FILE does not exist.
MTIME is the modification time of the file FILE names, its symbolic
links followed."
  (cons file (file-attribute-modification-time
              (file-attributes (file-chase-links file)))))

(defun latex-to-svg-backend--preamble-files (files option)
  "Return the stamps of FILES, the value of OPTION, for the current buffer.
That is a list of (NAME . MTIME) pairs (see
`latex-to-svg-backend--preamble-file-stamp'), each NAME expanded in
the directory `\\input' searches (`latex-to-svg-backend--input-directory'),
or nil when FILES is nil or that directory is refused.  A file that
does not exist is reported once per buffer (see
`latex-to-svg-backend--warn')."
  (when-let* ((files files)
              (dir (latex-to-svg-backend--input-directory)))
    (mapcar (lambda (name)
              (let ((stamp (latex-to-svg-backend--preamble-file-stamp
                            (expand-file-name name dir))))
                (unless (cdr stamp)
                  (latex-to-svg-backend--warn
                   (concat "missing preamble file/" (car stamp))
                   (format "`%s' names %s, which does not exist.
Correct the name in `%s', or remove it." option (car stamp) option)))
                stamp))
            files)))

(defun latex-to-svg-backend--same-file-stamps-p (old new)
  "Return non-nil when the (NAME . MTIME) lists OLD and NEW are the same.
They are when they name the same files in the same order, each with the
same modification time, or each missing."
  (and (= (length old) (length new))
       (seq-every-p
        #'identity
        (seq-mapn (lambda (a b)
                    (and (equal (car a) (car b))
                         (if (cdr a)
                             (and (cdr b) (time-equal-p (cdr a) (cdr b)))
                           (null (cdr b)))))
                  old new))))

(defun latex-to-svg-backend--latex-inputs ()
  "Return what the LaTeX engine reads from the current buffer, as a plist.
That is `(:preamble PREAMBLE :macros TEXT :package-files PACKAGE-FILES
:macro-files MACRO-FILES)': the texts of `latex-to-svg-backend--preamble'
and `latex-to-svg-backend--macros', and the stamps of
`latex-to-svg-backend-preamble-package-files' and
`latex-to-svg-backend-preamble-not-precompiled-files' (see
`latex-to-svg-backend--preamble-files').  A request reads them once,
in the buffer that makes it, and passes them on: a compile may start
from another compile's sentinel, and a fallback from its own, where the
current buffer is another."
  (list :preamble (latex-to-svg-backend--preamble)
        :macros (latex-to-svg-backend--macros)
        :package-files (latex-to-svg-backend--preamble-files
                        latex-to-svg-backend-preamble-package-files
                        'latex-to-svg-backend-preamble-package-files)
        :macro-files (latex-to-svg-backend--preamble-files
                      latex-to-svg-backend-preamble-not-precompiled-files
                      'latex-to-svg-backend-preamble-not-precompiled-files)))

(defun latex-to-svg-backend--latex-cache-salt (inputs)
  "Return what `latex-to-svg-backend--cache-key' folds in for LaTeX.
INPUTS is as for `latex-to-svg-backend--latex-inputs'.  That is the
preamble, then the macros text when it is not empty, then the stamps
of the preamble's files when there are any, so an empty option leaves
the key as it was before the option existed."
  (let ((macros (plist-get inputs :macros))
        (files (append (plist-get inputs :package-files)
                       (plist-get inputs :macro-files))))
    (concat (plist-get inputs :preamble)
            (unless (string-empty-p macros)
              (concat "\n" macros))
            (when files
              (concat "\n" (prin1-to-string files))))))

;;;; Preamble precompilation (.fmt)

;; Speedup: dump the preamble (class + packages) to a LaTeX `.fmt' file once,
;; with TeX's `\dump', then load it from every equation compile with a `%&'
;; first line instead of re-reading and re-loading amsmath/xcolor/... each
;; time.  A failed dump stops the compiles with its preamble until one of
;; the files its stamp names changes: each would fail on the preamble's
;; error, and report it once per equation.

(defun latex-to-svg-backend--tex-command (&optional program)
  "Return the TeX PROGRAM as a list of the program and its first arguments.
PROGRAM is a program name or such a list, nil meaning
`latex-to-svg-backend-latex-program'.  The arguments come before those
of the compile and of the dump of the `.fmt' file."
  (if (consp program)
      program
    (list (or program latex-to-svg-backend-latex-program))))

(defun latex-to-svg-backend--latex-binary (&optional program)
  "Return the path to the LaTeX executable, or nil.
PROGRAM is the TeX program (see `latex-to-svg-backend--tex-command').
Honours an absolute PROGRAM, else resolves the command name on variable
`exec-path'.  Used for the freshness check of the `.fmt' file."
  (let ((prog (car (split-string
                    (car (latex-to-svg-backend--tex-command program))))))
    (if (file-name-absolute-p prog)
        (and (file-executable-p prog) prog)
      (executable-find prog))))

(defun latex-to-svg-backend--latex-format-name (&optional program)
  "Return the name of the LaTeX `.fmt' file the dump starts from.
That is the `&NAME' of the `-ini' run, e.g. \"latex\" for `latex.fmt':
the name of PROGRAM (see `latex-to-svg-backend--tex-command'), or, as
in TeX, the NAME of a `-progname=NAME' argument of PROGRAM."
  (let ((command (latex-to-svg-backend--tex-command program)))
    (or (seq-some (lambda (arg)
                    (and (string-match "\\`-progname=\\(.+\\)" arg)
                         (match-string 1 arg)))
                  (cdr command))
        (file-name-nondirectory (car (split-string (car command)))))))

(defun latex-to-svg-backend--format-key (preamble &optional program)
  "Return the cache key naming the precompiled `.fmt' file of PREAMBLE.
PREAMBLE is the text of `latex-to-svg-backend--preamble'.  Folds in
PREAMBLE and the TeX PROGRAM that dumps it (see
`latex-to-svg-backend--tex-command'), so any change to either yields a
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
The stamp names the files FORMAT-FILE was dumped from (see
`latex-to-svg-backend--format-stamp')."
  (concat (file-name-sans-extension format-file) ".eld"))

(defun latex-to-svg-backend--format-log-file (format-file)
  "Return the path of the log of the dump of FORMAT-FILE.
TeX writes it next to FORMAT-FILE; the dump keeps it when it fails (see
`latex-to-svg-backend--build-format'), as a failed compile keeps the
equation's (see `latex-to-svg-backend--log-file')."
  (concat (file-name-sans-extension format-file) ".log"))

(defun latex-to-svg-backend--recorded-inputs (fls)
  "Return the absolute names of the files TeX read, from FLS.
FLS is the file list `-recorder' makes TeX write; nil when it is
missing, as from a TeX that does not write one."
  (when (file-readable-p fls)
    (with-temp-buffer
      (insert-file-contents fls)
      (let ((files nil))
        (while (re-search-forward "^INPUT \\(.+\\)$" nil t)
          (let ((file (match-string 1)))
            (when (file-name-absolute-p file)
              (push file files))))
        (delete-dups (nreverse files))))))

(defun latex-to-svg-backend--tree-indexes (files)
  "Return the `ls-R' files of the TeX trees holding FILES.
kpathsea finds a tree's files through the `ls-R' at its root, so
whatever installs or updates files in the tree regenerates it with
`mktexlsr': `tlmgr', and the package managers of the Linux
distributions.  A file in no such tree adds nothing."
  (let ((seen (make-hash-table :test 'equal))
        (indexes nil))
    (dolist (file files)
      (let ((dir (file-name-directory file))
            (found nil))
        (while (and dir (not found) (not (gethash dir seen)))
          (puthash dir t seen)
          (let ((index (expand-file-name "ls-R" dir))
                (parent (file-name-directory (directory-file-name dir))))
            (if (file-exists-p index)
                (setq found index)
              (setq dir (unless (equal parent dir) parent)))))
        (when found
          (push found indexes))))
    (nreverse indexes)))

(defun latex-to-svg-backend--format-stamp (binary &optional inputs
                                                   package-files failed)
  "Return the stamp of a `.fmt' file dumped by the LaTeX BINARY.
INPUTS are the files the dump read (see
`latex-to-svg-backend--recorded-inputs'), and PACKAGE-FILES the stamps
of `latex-to-svg-backend-preamble-package-files' (see
`latex-to-svg-backend--preamble-files').  FAILED non-nil says the dump
failed.  The stamp is a plist whose values, but the last, are (NAME .
MTIME) pairs (see
`latex-to-svg-backend--file-stamp'):

  :binary     BINARY.  An upgrade of TeX replaces the binary, which
              changes its modification time; another TeX first on
              variable `exec-path' changes either.
  :latex-fmt  the distribution's `.fmt' file the dump started from,
              such as `latex.fmt', which the distribution dumps again
              when its kernel or its binary is updated.
  :ls-r       a list, the `ls-R' file of each TeX tree the dump read
              from (see `latex-to-svg-backend--tree-indexes'), which
              changes when a package is updated.
  :preamble-package-files
              a list, PACKAGE-FILES.
  :failed     t.

The second and third are missing without INPUTS, the fourth without
PACKAGE-FILES, the last without FAILED.  As in the failure record of an
equation, the log is not named: it is found from the stamp's name (see
`latex-to-svg-backend--format-log-file').  A dump that failed has no
`.fmt' file, and its stamp is checked as one that succeeded (see
`latex-to-svg-backend--format-fresh-p'): the preamble is dumped again
once a file the stamp names has changed."
  (let ((base (seq-find (lambda (file) (string-suffix-p ".fmt" file))
                        inputs))
        (indexes (delq nil (mapcar #'latex-to-svg-backend--file-stamp
                                   (latex-to-svg-backend--tree-indexes
                                    inputs)))))
    (append (list :binary (latex-to-svg-backend--file-stamp binary))
            (when-let* ((entry (and base (latex-to-svg-backend--file-stamp
                                          base))))
              (list :latex-fmt entry))
            (when indexes
              (list :ls-r indexes))
            (when package-files
              (list :preamble-package-files package-files))
            (when failed
              (list :failed t)))))

(defun latex-to-svg-backend--read-format-stamp (format-file)
  "Return the stamp of FORMAT-FILE, or nil when it cannot be read.
An unreadable stamp is nil with no warning: the `.fmt' file is then
stale, and the dump writes a new stamp, and warns when it cannot (see
`latex-to-svg-backend--write-format-stamp')."
  (let ((file (latex-to-svg-backend--format-stamp-file format-file)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (read (current-buffer)))
        ((end-of-file invalid-read-syntax file-error) nil)))))

(defun latex-to-svg-backend--format-fresh-p (stamp binary
                                                   &optional package-files)
  "Return non-nil when the `.fmt' file of STAMP is fresh for BINARY.
STAMP is a plist of `latex-to-svg-backend--format-stamp', or an
equation's failure record, which holds such a stamp (see
`latex-to-svg-backend--record-failure').  It is fresh
when its binary is BINARY, every file it names exists with the
modification time it records, and its preamble package files are
PACKAGE-FILES, the request's stamps of
`latex-to-svg-backend-preamble-package-files'.  A stamp written before
0.16.0 names the binary by a string, and is stale, so its `.fmt' file
is dumped again once; so is a `.fmt' file with no stamp."
  (let ((entry (and (consp stamp) (plist-get stamp :binary))))
    (and (consp entry)
         (equal (car entry) (file-chase-links binary))
         (latex-to-svg-backend--file-unchanged-p entry)
         (seq-every-p #'latex-to-svg-backend--file-unchanged-p
                      (append (when-let* ((base (plist-get stamp :latex-fmt)))
                                (list base))
                              (plist-get stamp :ls-r)))
         (latex-to-svg-backend--same-file-stamps-p
          (plist-get stamp :preamble-package-files) package-files))))

(defun latex-to-svg-backend--toolchain-stamp (binary format-stamp)
  "Return the stamp of a failed compile by the TeX BINARY.
FORMAT-STAMP is the stamp of the `.fmt' file the compile loaded (see
`latex-to-svg-backend--format-stamp'), nil when it loaded none.  The
result is FORMAT-STAMP's `:binary', `:latex-fmt' and `:ls-r', which
`latex-to-svg-backend--ensure-format' found fresh before the compile;
without a `.fmt' file, the `:binary' of BINARY only.  It goes into the
equation's failure record (see `latex-to-svg-backend--record-failure'),
which a request then checks as a `.fmt' stamp (see
`latex-to-svg-backend--format-fresh-p'): an update of TeX, or of a
package, compiles the equation again."
  (if format-stamp
      (append (list :binary (plist-get format-stamp :binary))
              (when-let* ((entry (plist-get format-stamp :latex-fmt)))
                (list :latex-fmt entry))
              (when-let* ((indexes (plist-get format-stamp :ls-r)))
                (list :ls-r indexes)))
    (and binary (latex-to-svg-backend--format-stamp binary))))

(defun latex-to-svg-backend--write-format-stamp (format-file binary
                                                             &optional inputs
                                                             package-files
                                                             failed)
  "Write the stamp of FORMAT-FILE, dumped by BINARY, and return it.
INPUTS, PACKAGE-FILES and FAILED are as for
`latex-to-svg-backend--format-stamp'.  A stamp that cannot be written
is reported once per buffer (see `latex-to-svg-backend--warn'); the
stamp still serves this session, and the preamble is dumped again in
the next."
  (let ((file (latex-to-svg-backend--format-stamp-file format-file))
        (stamp (latex-to-svg-backend--format-stamp
                binary inputs package-files failed)))
    (condition-case err
        (with-temp-file file
          (prin1 stamp (current-buffer)))
      (file-error
       (latex-to-svg-backend--warn
        "writing a .fmt stamp"
        (format "Cannot write %s: %s.
The preamble is precompiled again in each session.  %s"
                file (error-message-string err)
                (latex-to-svg-backend--cache-fix)))))
    stamp))

(defun latex-to-svg-backend--touch-format (format-file)
  "Bump FORMAT-FILE's modification time and return FORMAT-FILE, or nil.
`latex-to-svg-backend-gc' deletes a `.fmt' file whose mtime is older
than `latex-to-svg-backend-cache-max-age', so this runs on every compile
that loads it: a session that runs for longer must not lose the `.fmt'
file it uses.  Nil means another session collected FORMAT-FILE a
moment ago; the caller then compiles with the full preamble.  Any other
refusal by the filesystem is reported once per buffer (see
`latex-to-svg-backend--warn') and FORMAT-FILE returned: the `.fmt' file
works, it only ages out."
  (condition-case err
      (progn (set-file-times format-file) format-file)
    (file-missing nil)
    (file-error
     (latex-to-svg-backend--warn
      "recording .fmt use"
      (format "Cannot record the use of %s: %s.
The garbage collector deletes a .fmt file unused for \
`latex-to-svg-backend-cache-max-age' days, and cannot tell that this \
one is in use.  %s"
              format-file (error-message-string err)
              (latex-to-svg-backend--cache-fix)))
     format-file)))

(defun latex-to-svg-backend--build-format (fkey preamble &optional program
                                                 package-files)
  "Dump PREAMBLE to the `.fmt' file for FKEY, synchronously.
Return the `.fmt' path on success, (failed . LOG) when the dump failed,
LOG its log, and nil when the TeX program could not be started.
Writes PREAMBLE followed by TeX's `\\dump' to a scratch `.tex' in the
`fmt/' subdirectory and runs the TeX PROGRAM on it in `-ini' mode (see
`latex-to-svg-backend--tex-command'), which writes
`<cache>/fmt/FKEY.fmt' and `<cache>/fmt/FKEY.log'.  The program's
output is in the `*latex-to-svg-backend-precompile-log*' buffer.
TeX's `-recorder' lists the files the dump read, from which the stamp
is written with PACKAGE-FILES (see
`latex-to-svg-backend--write-format-stamp') and kept in
`latex-to-svg-backend--format-stamps'.

A preamble that will not dump makes TeX exit non-zero.  The stamp is
then written as well, marked failed, and the log is kept; the failure
is reported each time, with no mark (see
`latex-to-svg-backend--report-failed-format').  A dump runs only when
its inputs changed, so the warnings come once per change.  A TeX
program that is not found signals `file-missing', which
`latex-to-svg-backend--ensure-format' handles; one that is found but
cannot be started is reported once per buffer (see
`latex-to-svg-backend--warn')."
  (let* ((dir (latex-to-svg-backend--fmt-dir))
         (base (expand-file-name fkey dir))
         (fmt (concat base ".fmt"))
         (pre-tex (concat base ".tex"))
         (log (latex-to-svg-backend--format-log-file fmt))
         (fls (concat base ".fls"))
         (buffer (get-buffer-create "*latex-to-svg-backend-precompile-log*")))
    (with-current-buffer buffer (erase-buffer))
    ;; Pin UTF-8: see `latex-to-svg-backend--compile' on why the encoding is
    ;; fixed on write rather than declared with `inputenc'.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file pre-tex
        (insert preamble "\n\\dump\n")))
    (message "latex-to-svg-backend: precompiling LaTeX preamble...")
    (let* ((command (latex-to-svg-backend--tex-command program))
           (tex (car command))
           (rv (unwind-protect
                   (condition-case err
                       (apply #'call-process tex
                              nil buffer nil
                              (append
                               (cdr command)
                               (list (concat "-output-directory=" dir)
                                     "-ini"
                                     "-recorder"
                                     (concat "-jobname=" fkey)
                                     (concat "&" (latex-to-svg-backend--latex-format-name
                                                  program))
                                     pre-tex)))
                     (file-missing (signal (car err) (cdr err)))
                     ;; Found but cannot be started.  Report it; the
                     ;; caller falls back to a full compile, which reports
                     ;; its own failure.
                     (file-error
                      (latex-to-svg-backend--warn
                       "dumping the LaTeX preamble"
                       (format "Cannot run %s to precompile the LaTeX \
preamble: %s.
Make %s executable, or set the engine's program in \
M-x customize-group RET latex-to-svg-backend."
                               tex (error-message-string err) tex))
                      nil))
                 (delete-file pre-tex))))
      (unwind-protect
          (let ((dumped (and (eql rv 0) (file-exists-p fmt))))
            (if dumped
                (delete-file log)
              (delete-file fmt))
            (when rv
              (when-let* ((binary (latex-to-svg-backend--latex-binary
                                   program)))
                (puthash fkey
                         (latex-to-svg-backend--write-format-stamp
                          fmt binary
                          (latex-to-svg-backend--recorded-inputs fls)
                          package-files
                          (not dumped))
                         latex-to-svg-backend--format-stamps)))
            (cond
             (dumped fmt)
             (rv
              (latex-to-svg-backend--report-failed-format log)
              (cons 'failed log))))
        (delete-file fls)))))

(defun latex-to-svg-backend--report-failed-format (log)
  "Warn that the dump of a `.fmt' file failed, LOG being its log.
Shown each time, in the current buffer (see
`latex-to-svg-backend--warn-always'): a cause marked once per buffer
would hide the failure of the next edit."
  (latex-to-svg-backend--warn-always
   (format "Precompiling the LaTeX preamble into a .fmt file failed; \
see %s.
No equation is compiled with this preamble until it is dumped again: \
after a change to the preamble options, to a file listed in \
`latex-to-svg-backend-preamble-package-files', or to the TeX \
installation.  After an edit of another file the preamble loads, \
M-x latex-to-svg-backend-invalidate-format dumps it again.  A package \
that cannot be dumped belongs in \
`latex-to-svg-backend-preamble-not-precompiled'."
           log)))

(defun latex-to-svg-backend--ensure-format (preamble &optional program
                                                    package-files)
  "Return the path of a fresh precompiled `.fmt' file of PREAMBLE, or nil.
PREAMBLE is the text of `latex-to-svg-backend--preamble'; PROGRAM is
the TeX program that dumps and loads it (see
`latex-to-svg-backend--tex-command'); PACKAGE-FILES are the stamps of
`latex-to-svg-backend-preamble-package-files' (see
`latex-to-svg-backend--preamble-files').  Dumps the `.fmt' file on first
use (synchronously) and caches it on disk.  Before each use it checks
the stamp, read once per session (see
`latex-to-svg-backend--format-stamps'), and dumps the `.fmt' file
again when a file the stamp names has changed (see
`latex-to-svg-backend--format-fresh-p'): another LaTeX binary, as
after a TeX toolchain upgrade, where `latex' would otherwise refuse the
`.fmt' file on every compile, an update of the distribution, or an
edit of one of PACKAGE-FILES.  Bumps
the mtime of the `.fmt' file it returns (see
`latex-to-svg-backend--touch-format').

Returns (failed . LOG) when the dump failed, LOG being its log (see
`latex-to-svg-backend--format-log-file'): the dump it runs, or an
earlier one whose stamp is fresh.  The caller then compiles nothing (see
`latex-to-svg-backend--format-failed').  Returns nil, so the caller
uses a full compile, when precompilation is off or PROGRAM cannot be
started.  When PROGRAM is not found, it returns nil and writes no
stamp, so the compile reports the missing program and the dump runs
once PROGRAM is installed."
  (when latex-to-svg-backend-precompile
    (let* ((fkey (latex-to-svg-backend--format-key preamble program))
           (fmt (latex-to-svg-backend--format-file fkey))
           (latex-bin (latex-to-svg-backend--latex-binary program))
           (stamp (or (gethash fkey latex-to-svg-backend--format-stamps)
                      (puthash fkey
                               (latex-to-svg-backend--read-format-stamp fmt)
                               latex-to-svg-backend--format-stamps)))
           (failed (and (consp stamp) (plist-get stamp :failed)))
           (fresh (and latex-bin
                       (latex-to-svg-backend--format-fresh-p
                        stamp latex-bin package-files))))
      (cond
       ((and failed fresh)
        (cons 'failed (latex-to-svg-backend--format-log-file fmt)))
       ((and (not failed) (file-exists-p fmt) (or (null latex-bin) fresh))
        (latex-to-svg-backend--touch-format fmt))
       (t
        ;; Missing, stale, or a failed dump whose inputs changed -> dump.
        (remhash fkey latex-to-svg-backend--format-stamps)
        (delete-file fmt)
        (delete-file (latex-to-svg-backend--format-stamp-file fmt))
        (condition-case nil
            (latex-to-svg-backend--build-format
             fkey preamble program package-files)
          (file-missing nil)))))))

(defun latex-to-svg-backend--format-failed (key engine log)
  "End the compile of KEY by ENGINE, whose preamble failed to dump.
LOG is the log of the dump (see `latex-to-svg-backend--build-format').
Every request waiting for KEY gets a `setup' failure whose `:log' is
LOG (see `latex-to-svg-backend--call-back').  Nothing is recorded for
the equation: the fault is in the preamble, and the equation's key
changes with the files the preamble loads.  Nothing is reported
either: the dump reported its failure."
  (let ((failure (latex-to-svg-backend--failure
                  'setup engine
                  :message (format "The %s engine could not precompile \
the preamble into a .fmt file."
                                   (latex-to-svg-backend--engine-name engine))
                  :log log)))
    (dolist (waiter (gethash key latex-to-svg-backend--pending))
      (latex-to-svg-backend--call-back (plist-get waiter :callback) failure))
    (latex-to-svg-backend--compile-done key)))

;;;###autoload
(defun latex-to-svg-backend-flush-format ()
  "Delete all precompiled `.fmt' files and forget them.

Removes every `.fmt' file in the cache `fmt/' subdirectory, with its
stamp, and the stamps of the dumps that failed, and forgets this
session's stamps, so the next render dumps a fresh `.fmt' file from the
current preamble.  An escape
hatch for a stale `.fmt' file the stamp missed — a TeX toolchain
upgrade or an update of the distribution is handled on its own (see
`latex-to-svg-backend--format-stamp'), so this is rarely needed."
  (interactive)
  (clrhash latex-to-svg-backend--format-stamps)
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
compile the equations again.  Deletes the `.fmt' file with its stamp,
or the stamp of a dump that failed, and forgets this session's stamp
for it, so the next compile dumps it again.  Other preambles'
`.fmt' files stay (see `latex-to-svg-backend-flush-format')."
  (interactive)
  (let ((preamble (latex-to-svg-backend--preamble)))
    (dolist (program (delete-dups
                      (mapcar #'funcall latex-to-svg-backend--format-programs)))
      (let* ((fkey (latex-to-svg-backend--format-key preamble program))
             (fmt (latex-to-svg-backend--format-file fkey)))
        (remhash fkey latex-to-svg-backend--format-stamps)
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
          ;; unplaced.  The sidecar is a cache, so report the failure and
          ;; let the equation through.
          (file-error
           (latex-to-svg-backend--warn-waiters
            key "writing compile metadata"
            (format "Cannot write %s: %s.
The equation's number is lost.  %s"
                    (latex-to-svg-backend--meta-file key)
                    (error-message-string err)
                    (latex-to-svg-backend--cache-fix)))))))))

(defconst latex-to-svg-backend--latex-environment
  '("error_line=254" "half_error_line=238" "max_print_line=1000")
  "Environment variables for the TeX program of a compile.
TeX Live's `latex' reads them from the environment.  They let the log
show the whole line of an error, which is cut to about 50 characters
otherwise, so `latex-to-svg-backend--latex-formula-error' finds its
column.  They change only the log's formatting, so they are not part of
the cache key.  texres reads them from version 0.7.9 on.")

(defun latex-to-svg-backend--latex-formula-error (dir latex offset)
  "Return the error LaTeX stopped on in the input, as a plist, or nil.
Nil when the log in scratch DIR shows no rejected input.  The input is
rejected when `equation.log' has a `! ' error line, such as \"! Undefined
control sequence.\" or \"! LaTeX Error: File `siunitx.sty' not found.\":
compiling the same document again fails the same way.  \"! I can't
write on file\" is a disk problem, not the input's, and does not count.

The plist is (:message MESSAGE :line LINE :column COLUMN).  MESSAGE is
the text after `! ', with the indented lines LaTeX breaks a long message
onto joined to it.  LINE is the 1-based line in LATEX of the `l.N' line
TeX prints after the error, where OFFSET is the number of lines
`equation.tex' holds before LATEX; nil when TeX names no line, or one
outside LATEX (`Missing $ inserted' at `\\end{document}', say).  COLUMN
is the 0-based column in that line where TeX stopped: TeX splits the
line there, and prints the text before it after `l.N '.  Nil when TeX
cut that text short, starting it with `...' (see
`latex-to-svg-backend--latex-environment').  pdfTeX prints the bytes of
a non-ASCII character, so the text is decoded as UTF-8 before it is
counted."
  (let ((log (expand-file-name "equation.log" dir)))
    (when (file-readable-p log)
      (with-temp-buffer
        (let ((coding-system-for-read 'raw-text))
          (insert-file-contents log))
        (goto-char (point-min))
        (when (and (re-search-forward "^! \\(.*\\)$" nil t)
                   (not (string-prefix-p "I can't write on file"
                                         (match-string 1))))
          (let ((message (match-string 1))
                ;; With `-halt-on-error' the next `! ' line is TeX's
                ;; "==> Fatal error occurred".
                (end (save-excursion
                       (if (re-search-forward "^! " nil t)
                           (match-beginning 0)
                         (point-max))))
                (line nil)
                (column nil))
            (forward-line 1)
            (while (looking-at "[ \t]+\\([^ \t\n].*\\)$")
              (setq message (concat message " " (match-string 1)))
              (forward-line 1))
            (when (re-search-forward "^l\\.\\([0-9]+\\) \\(.*\\)$" end t)
              (let ((n (- (string-to-number (match-string 1)) offset))
                    (before (match-string 2)))
                (when (<= 1 n (1+ (seq-count (lambda (c) (eq c ?\n)) latex)))
                  (setq line n
                        column (unless (string-prefix-p "..." before)
                                 (length (decode-coding-string
                                          before 'utf-8)))))))
            (list :message (string-trim (decode-coding-string message 'utf-8))
                  :line line
                  :column column)))))))

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
  :program  the TeX program (see `latex-to-svg-backend--tex-command');
  :output   the file the TeX program writes in the scratch directory;
  :prefix   text written after `\\begin{document}', before the equation;
  :suffix   text written after the equation, before `\\end{document}';
  :convert  a function of the scratch directory and the TeX output
            file, returning the stages that make an SVG in the scratch
            directory (see `latex-to-svg-backend--run-process-chain');
  :store    a function of the scratch directory and the cache SVG run
            after the stages, that returns non-nil once the cache SVG
            is written, by `latex-to-svg-backend--move-to-cache'.

The LaTeX engine's `dvisvgm' writes the SVG as it is cached, and the
store moves it to the cache.  It runs at
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
        :convert (lambda (dir dvi)
                   (let ((svg (expand-file-name "equation.svg" dir)))
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
                            svg))))
        :store (lambda (dir svg)
                 (latex-to-svg-backend--move-to-cache
                  (expand-file-name "equation.svg" dir) svg))))

(defun latex-to-svg-backend--compile
    (key latex &optional metadata inputs toolchain)
  "Asynchronously compile LATEX to the color-independent cache SVG for KEY.
METADATA, when non-nil, is stored as the INITIAL value in KEY's `.eld'
sidecar alongside the FINAL captured from the log (see
`latex-to-svg-backend--write-metadata').  INPUTS is the plist of
`latex-to-svg-backend--latex-inputs', nil meaning the current buffer's.
TOOLCHAIN is the plist of
`latex-to-svg-backend--latex-toolchain', nil meaning that one; another
engine that compiles with LaTeX passes its own.

LATEX is placed verbatim in the document body (the caller supplies
valid body LaTeX and chooses inline vs display via delimiters).
Writes a standalone LaTeX document, runs the TeX program and then the
TOOLCHAIN's stages in a scratch directory (see
`latex-to-svg-backend--scratch-dir'), and on success caches the
SVG and notifies every callback queued for KEY (see
`latex-to-svg-backend--enqueue').  The scratch directory is removed
when the process exits.

The preamble is loaded from a precompiled `.fmt' file when one is
available (see `latex-to-svg-backend-precompile'), via a `%&' first line;
otherwise the full preamble is embedded in the document.  When the
dump of the preamble failed, nothing is compiled (see
`latex-to-svg-backend--format-failed').  A failure is
handled by `latex-to-svg-backend--compile-failed': the log is saved,
and when the TeX program stopped on an error in the document (see
`latex-to-svg-backend--latex-formula-error') the failure is recorded,
with the stamp of the TeX installation (see
`latex-to-svg-backend--toolchain-stamp').
The `.fmt' file stays: its stamp, checked before it is loaded, decides
whether it is stale (see `latex-to-svg-backend--format-fresh-p').

No color is baked in: the equation's default ink becomes the literal
`currentColor', so the SVG is color-independent and is tinted to the
caller's `:color' at display time (`latex-to-svg-backend--load-svg-image').
A theme change therefore re-tints from cache without recompiling."
  (let* ((toolchain (or toolchain (latex-to-svg-backend--latex-toolchain)))
         (inputs (or inputs (latex-to-svg-backend--latex-inputs)))
         (preamble (plist-get inputs :preamble))
         (program (plist-get toolchain :program))
         (format-file (latex-to-svg-backend--ensure-format
                       preamble program (plist-get inputs :package-files))))
    (if (eq (car-safe format-file) 'failed)
        (latex-to-svg-backend--format-failed
         key (plist-get toolchain :engine) (cdr format-file))
      (let* ((command (latex-to-svg-backend--tex-command program))
             (binary (latex-to-svg-backend--latex-binary program))
             (format-stamp
              (and format-file
                   (gethash (latex-to-svg-backend--format-key preamble program)
                            latex-to-svg-backend--format-stamps)))
             (store (plist-get toolchain :store))
             (dir (latex-to-svg-backend--scratch-dir))
             (tex (expand-file-name "equation.tex" dir))
             (output (expand-file-name (plist-get toolchain :output) dir))
             (svg (latex-to-svg-backend--svg-file key))
             (macros (plist-get inputs :macros))
             ;; Everything before LATEX.  Its lines are counted, so that an
             ;; error's line in `equation.tex' becomes a line in LATEX.
             (head (concat (if format-file
                               ;; Load the precompiled preamble: the `%&' line
                               ;; must be first, and names the `.fmt' file by
                               ;; absolute path without its `.fmt' extension.
                               ;; The class + packages are already in the
                               ;; `.fmt' file, so they are not written here.
                               (concat "%& " (file-name-sans-extension format-file)
                                       "\n")
                             (concat preamble "\n"))
                           (if (string-empty-p macros)
                               ""
                             (concat macros "\n"))
                           "\\begin{document}\n"
                           (plist-get toolchain :prefix)))
             (offset (seq-count (lambda (c) (eq c ?\n)) head))
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
            (insert head
                    ;; LATEX is inserted verbatim: it already carries its own
                    ;; math delimiters / environment (chosen by the
                    ;; front-end), which also decide inline vs display sizing.
                    ;; A newline after it, so that a `%' comment at the end of
                    ;; LATEX does not hide the suffix.
                    latex "\n"
                    (or (plist-get toolchain :suffix) "")
                    "\\end{document}\n")))
        (latex-to-svg-backend--run-process-chain
         key dir output-buffer
         (cons (list 'latex
                     ;; TeX reads its command line as a line of input, and the
                     ;; name of the cache directory may hold characters TeX
                     ;; reads as code: name the file in DIR, where TeX runs.
                     (append command
                             (list "-interaction=nonstopmode"
                                   "-halt-on-error"
                                   "equation.tex"))
                     output
                     latex-to-svg-backend--latex-environment)
               (funcall (plist-get toolchain :convert) dir output))
         (lambda (success &optional exit)
           (let* ((stored
                   (and success
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
             (unwind-protect
                 (if stored
                     (progn
                       ;; Capture compile metadata before DIR is cleaned up.
                       (latex-to-svg-backend--write-metadata key dir metadata)
                       (latex-to-svg-backend--notify-pending key))
                   (let ((fault (and (eq (car exit) 'latex)
                                     (latex-to-svg-backend--latex-formula-error
                                      dir latex offset))))
                     (latex-to-svg-backend--compile-failed
                      key latex dir
                      (latex-to-svg-backend--process-output output-buffer)
                      (plist-get toolchain :engine) fault exit
                      (and fault
                           (latex-to-svg-backend--toolchain-stamp
                            binary format-stamp)))))
               (latex-to-svg-backend--compile-done key)
               (when (buffer-live-p output-buffer)
                 (kill-buffer output-buffer))
               (funcall cleanup)))))))))

(defun latex-to-svg-backend--warn-obsolete-alias (alias)
  "Warn that ALIAS, an obsolete alias, is set.
The warning says what `make-obsolete-variable' recorded for ALIAS: the
version and the option to set instead, or the text that says what to
do instead.  Emacs reports an obsolete variable only when it compiles
the code that sets it, which an init file seldom is.  Called at load,
where no buffer requested anything, so it does not go through
`latex-to-svg-backend--warn'."
  (pcase-let ((`(,current ,_ ,version) (get alias 'byte-obsolete-variable)))
    (display-warning
     'latex-to-svg-backend
     (if (stringp current)
         (format "`%s' is obsolete since %s; %s." alias version current)
       (format "`%s' is obsolete since %s; use `%s' instead."
               alias version current))
     :warning)))

(mapc #'latex-to-svg-backend--warn-obsolete-alias
      latex-to-svg-backend--obsolete-aliases-set)

(provide 'latex-to-svg-backend-latex)

;;; latex-to-svg-backend-latex.el ends here
