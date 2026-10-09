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

(defun latex-to-svg-backend--texres-store (dir svg)
  "Write the SVG `pdftocairo' left in DIR to the cache file SVG.
The SVG is cropped to its ink, with the marker ink as `currentColor'
\(see `latex-to-svg-backend--crop-to-ink').  Return non-nil on
success, nil when the output has no SVG root element."
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
          (insert data)))
      t)))

;;;; Compile

(defun latex-to-svg-backend--texres-toolchain ()
  "Return the toolchain of the texres engine, or signal an error.
That is texres's `pdflatex', then `pdftocairo -svg -noshrink' (see
`latex-to-svg-backend--latex-toolchain' for the plist).  Without
`-noshrink', `pdftocairo' scales a small page's content down by a
few percent."
  (list :engine 'texres
        :program (or (latex-to-svg-backend--texres-link)
                     (error "Cannot find texres: %s"
                            latex-to-svg-backend-texres-program))
        :output "equation.pdf"
        :prefix latex-to-svg-backend--texres-ink
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
