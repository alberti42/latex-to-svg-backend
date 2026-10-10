;;; latex-to-svg-backend-texres.el --- texres engine of latex-to-svg-backend -*- lexical-binding: t -*-

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
;; The texres engine of `latex-to-svg-backend': it compiles an equation
;; with the `pdflatex' of texres <https://github.com/leoliu0/texres>, a
;; TeX distribution in a single executable written in Rust, then converts
;; the PDF with Poppler's `pdftocairo -svg' and crops the SVG to its ink.
;; It reads the LaTeX engine's preamble options and dumps its own `.fmt'
;; file.  Load `latex-to-svg-backend', not this file.

;;; Code:

(require 'latex-to-svg-backend-core)
(require 'latex-to-svg-backend-latex)

(defgroup latex-to-svg-backend-texres nil
  "The texres engine of `latex-to-svg-backend': texres + `pdftocairo'."
  :group 'latex-to-svg-backend
  :prefix "latex-to-svg-backend-")

;;;; Customization

(defcustom latex-to-svg-backend-texres-program "texres"
  "Program of texres, the TeX distribution the texres engine runs.
The engine runs it as `pdflatex' (see `latex-to-svg-backend--texres-link').
The preamble options of the LaTeX engine apply, starting with
`latex-to-svg-backend-preamble'."
  :type 'string
  :group 'latex-to-svg-backend-texres)

(defcustom latex-to-svg-backend-pdftocairo-program "pdftocairo"
  "Program that converts the texres engine's PDF to SVG.
This is `pdftocairo' from Poppler <https://poppler.freedesktop.org>."
  :type 'string
  :group 'latex-to-svg-backend-texres)

;;;; Capability

(defun latex-to-svg-backend--texres-link ()
  "Return a link named `pdflatex' to texres, creating it, or nil.
texres runs one `pdflatex' pass only when called by that name.  The
link is in the `texres/' subdirectory of the cache, so it shadows no
`pdflatex' on the variable `exec-path'.  Nil when texres is not found,
or when the link cannot be made, which is reported once.

A stopgap until texres can be told the program name without a link."
  (when-let* ((texres (executable-find latex-to-svg-backend-texres-program)))
    (let ((link (expand-file-name "pdflatex"
                                  (latex-to-svg-backend--subdir "texres")))
          (target (file-truename texres)))
      (unless (equal (file-symlink-p link) target)
        (condition-case err
            (make-symbolic-link target link t)
          (file-error
           (latex-to-svg-backend--warn-once "linking pdflatex to texres" err))))
      (and (equal (file-symlink-p link) target) link))))

(add-to-list 'latex-to-svg-backend--format-programs
             #'latex-to-svg-backend--texres-link t)

(defun latex-to-svg-backend--texres-tools-available-p ()
  "Return non-nil when texres and `pdftocairo' are found.
texres is looked up through `latex-to-svg-backend--texres-link'."
  (and (executable-find latex-to-svg-backend-pdftocairo-program)
       (latex-to-svg-backend--texres-link)))

;;;; Cache key

(defun latex-to-svg-backend--texres-cache-salt (inputs)
  "Return the text the texres engine folds into the cache key.
INPUTS is as for `latex-to-svg-backend--latex-inputs'.  The engine's
name keeps its SVGs apart from the LaTeX engine's, which reads the same
preamble."
  (concat "texres\0" (latex-to-svg-backend--latex-cache-salt inputs)))

;;;; SVG

(defconst latex-to-svg-backend--texres-ink
  "\\ifdefined\\definecolorset\\color[RGB]{1,2,3}\\fi\n"
  "Text before the equation that draws its default ink in a marker color.
`pdftocairo' writes the marker as `latex-to-svg-backend--texres-ink-svg',
which the engine replaces with `currentColor', so a formula's own
`\\color{black}' keeps its color.  `\\definecolorset' is defined only by
`xcolor', which the default preamble loads.")

(defconst latex-to-svg-backend--texres-ink-svg
  "rgb(0\\.3[0-9]*%, 0\\.7[0-9]*%, 1\\.1[0-9]*%)"
  "Regexp matching how `pdftocairo' writes the marker ink.
For RGB 1,2,3 it writes rgb(0.390625%, 0.782776%, 1.174927%).")

(defconst latex-to-svg-backend--texres-black-svg
  (regexp-quote "rgb(0%, 0%, 0%)")
  "Regexp matching how `pdftocairo' writes black.
Without `xcolor' there is no marker, and no `\\color' in a formula
either, so black is the default ink.")

(defconst latex-to-svg-backend--texres-baseline-mark
  (concat "\\ifhmode\\ifnum\\prevgraf=0 \\pdfsavepos"
          "\\write-1{latex-to-svg-backend-baseline"
          " \\the\\pdflastypos\\space\\the\\pdfpageheight}\\fi\\fi\n")
  "Text after the equation that logs the baseline of its line.
`\\pdfsavepos' records the position, and the `\\write', which runs when
the page is shipped out, logs its height above the page's bottom, in
sp, with the page's height.  It is written only while `\\prevgraf' is
0, for the reason `latex-to-svg-backend--latex-baseline-mark' gives.
`latex-to-svg-backend--texres-baseline' reads it.")

(defconst latex-to-svg-backend--texres-x-height-mark
  (concat "\\begingroup" latex-to-svg-backend--latex-x-height-tex
          "\\immediate\\write-1{latex-to-svg-backend-x-height \\the\\dimen0}"
          "\\endgroup\n")
  "Text after the equation that logs the x-height of its font.
See `latex-to-svg-backend--latex-x-height-tex'; pdftocairo ignores the
special the LaTeX engine uses, so texres logs the value, and
`latex-to-svg-backend--texres-store' writes it into the SVG.")

(defun latex-to-svg-backend--texres-log-value (dir regexp)
  "Return the groups of REGEXP's match in the log of the compile in DIR.
A list of the matched strings, or nil when the log has no match."
  (let ((log (expand-file-name "equation.log" dir)))
    (when (file-exists-p log)
      (with-temp-buffer
        (let ((coding-system-for-read 'raw-text))
          (insert-file-contents log))
        (when (re-search-forward regexp nil t)
          (cl-loop for i from 1 to (/ (length (match-data)) 2)
                   while (match-beginning i)
                   collect (match-string i)))))))

(defun latex-to-svg-backend--texres-x-height (dir)
  "Return the x-height the compile in DIR logged, in bp, or nil.
See `latex-to-svg-backend--texres-x-height-mark'."
  (when-let* ((value (latex-to-svg-backend--texres-log-value
                      dir "^latex-to-svg-backend-x-height \\([0-9.]+\\)pt$")))
    (string-to-number (car value))))

(defun latex-to-svg-backend--texres-baseline (dir)
  "Return the baseline the compile in DIR logged, in SVG coordinates, or nil.
See `latex-to-svg-backend--texres-baseline-mark'.  pdftocairo puts the
page's top at y 0 and writes big points, 72.27 of them to 72pt."
  (when-let* ((value (latex-to-svg-backend--texres-log-value
                      dir (concat "^latex-to-svg-backend-baseline"
                                  " \\([0-9]+\\) \\([0-9.]+\\)pt$"))))
    (* (- (string-to-number (nth 1 value))
          (/ (string-to-number (nth 0 value)) 65536.0))
       (/ 72 72.27))))

(defun latex-to-svg-backend--texres-store (dir svg)
  "Write the SVG `pdftocairo' left in DIR to the cache file SVG.
The SVG is cropped to its ink, with the marker ink as `currentColor'
\(see `latex-to-svg-backend--crop-to-ink'), and gives the baseline and
the x-height the compile logged (see `latex-to-svg-backend--texres-baseline'
and `latex-to-svg-backend--texres-x-height').  Return
non-nil on success, nil when the output has no SVG root element."
  (let* ((raw (with-temp-buffer
                (let ((coding-system-for-read 'utf-8))
                  (insert-file-contents (expand-file-name "cairo.svg" dir)))
                (buffer-string)))
         (data (latex-to-svg-backend--crop-to-ink
                raw (if (string-match-p latex-to-svg-backend--texres-ink-svg raw)
                        latex-to-svg-backend--texres-ink-svg
                      latex-to-svg-backend--texres-black-svg))))
    (when data
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file svg
          (insert (latex-to-svg-backend--mark-x-height
                   (latex-to-svg-backend--mark-baseline
                    data (latex-to-svg-backend--texres-baseline dir))
                   (latex-to-svg-backend--texres-x-height dir)))))
      t)))

;;;; Compile

(defun latex-to-svg-backend--texres-toolchain ()
  "Return the toolchain of the texres engine.
That is texres's `pdflatex', then `pdftocairo -svg -noshrink' (see
`latex-to-svg-backend--latex-toolchain' for the plist).  Without
`-noshrink', `pdftocairo' scales a small page's content down by a
few percent.  When there is no link (see
`latex-to-svg-backend--texres-link'), texres is run by its own name,
so a texres that is not found fails to start, as any missing program
does (see `latex-to-svg-backend--compile-failed')."
  (list :engine 'texres
        :program (or (latex-to-svg-backend--texres-link)
                     latex-to-svg-backend-texres-program)
        :output "equation.pdf"
        :prefix latex-to-svg-backend--texres-ink
        :suffix (concat latex-to-svg-backend--texres-baseline-mark
                        latex-to-svg-backend--texres-x-height-mark)
        :convert (lambda (dir pdf _svg)
                   (let ((out (expand-file-name "cairo.svg" dir)))
                     (list (list 'pdftocairo
                                 (list latex-to-svg-backend-pdftocairo-program
                                       "-svg" "-noshrink" pdf out)
                                 out))))
        :store #'latex-to-svg-backend--texres-store))

(defun latex-to-svg-backend--texres-compile (key latex &optional metadata inputs)
  "Asynchronously compile LATEX with texres to the cache SVG for KEY.
METADATA and INPUTS are as for `latex-to-svg-backend--compile', which
runs the compile with `latex-to-svg-backend--texres-toolchain'."
  (latex-to-svg-backend--compile
   key latex metadata inputs nil (latex-to-svg-backend--texres-toolchain)))

(provide 'latex-to-svg-backend-texres)

;;; latex-to-svg-backend-texres.el ends here
