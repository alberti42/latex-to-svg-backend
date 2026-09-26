;;; latex-to-svg-backend-ratex.el --- RaTeX engine of latex-to-svg-backend -*- lexical-binding: t -*-

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
;; The RaTeX engine of `latex-to-svg-backend': it typesets an equation
;; with the `render-svg' program of RaTeX
;; <https://github.com/erweixin/RaTeX>, a math renderer written in Rust
;; that parses KaTeX's syntax and needs no TeX installation.  Load
;; `latex-to-svg-backend', not this file.

;;; Code:

(require 'latex-to-svg-backend-core)

(defgroup latex-to-svg-backend-ratex nil
  "The RaTeX engine of `latex-to-svg-backend': RaTeX's `render-svg'."
  :group 'latex-to-svg-backend
  :prefix "latex-to-svg-backend-")

;;;; Customization

(defcustom latex-to-svg-backend-ratex-program "render-svg"
  "Program that renders a formula to SVG with RaTeX.
This is the `render-svg' binary of the RaTeX release archives
<https://github.com/erweixin/RaTeX/releases>, which are built with the
KaTeX fonts inside the binary."
  :type 'string
  :group 'latex-to-svg-backend-ratex)

(defcustom latex-to-svg-backend-ratex-macros ""
  "Macro definitions put in front of every formula RaTeX renders.
RaTeX has no preamble and loads no packages: it parses one formula at a
time, and a definition applies only to the formula that contains it.
This text is therefore prepended to each formula, so a `\\newcommand',
`\\renewcommand' or `\\def' here applies to every equation.

`\\newcommand' signals an error for a name RaTeX already defines
\(`\\R', `\\ket', ...); use `\\renewcommand' or `\\def' for those.

The value is folded into the cache key, so changing it re-renders."
  :type 'string
  :group 'latex-to-svg-backend-ratex)

;;;; Capability

(defun latex-to-svg-backend--ratex-tools-available-p ()
  "Return non-nil when RaTeX's `render-svg' is on the variable `exec-path'."
  (executable-find latex-to-svg-backend-ratex-program))

;;;; Cache key

(defun latex-to-svg-backend--ratex-cache-salt ()
  "Return the text the RaTeX engine folds into the cache key.
The engine's name keeps its SVGs apart from the LaTeX engine's, and
`latex-to-svg-backend-ratex-macros' is part of every formula."
  (concat "ratex\0" latex-to-svg-backend-ratex-macros))

;;;; Formula

(defconst latex-to-svg-backend--ratex-delimiters
  '(("$$" "$$" nil) ("\\[" "\\]" nil) ("\\(" "\\)" t) ("$" "$" t))
  "Math delimiters the RaTeX engine removes, as (OPEN CLOSE INLINE).
RaTeX parses math only and rejects `\\(' and `\\['.  INLINE non-nil
typesets the body in text style (`render-svg --inline'); a nil INLINE,
and a formula with none of these delimiters (an `equation' environment,
say), is typeset in display style.  `$$' comes before `$' so that a
display formula is not read as an inline one.")

(defun latex-to-svg-backend--ratex-one-line (text)
  "Return TEXT without its `%' comments and with its lines joined.
`render-svg' reads one formula per line."
  (string-trim
   (replace-regexp-in-string
    "\n" " "
    ;; A `%' starts a comment unless a backslash escapes it; in `\\%' the
    ;; backslash is itself escaped, so the `%' does start one.
    (replace-regexp-in-string
     "\\(?:^\\|[^\\]\\)\\(?:\\\\\\\\\\)*\\(%.*\\)$" "" text t t 1))))

(defun latex-to-svg-backend--ratex-formula (latex)
  "Return (FORMULA . INLINE) for rendering LATEX with RaTeX.
FORMULA is LATEX on one line (see `latex-to-svg-backend--ratex-one-line')
with its outer delimiter removed (see
`latex-to-svg-backend--ratex-delimiters') and
`latex-to-svg-backend-ratex-macros' in front.  INLINE is non-nil when
the delimiter was an inline one."
  (let* ((body (latex-to-svg-backend--ratex-one-line latex))
         (delimiter
          (seq-find (pcase-lambda (`(,open ,close ,_))
                      (and (>= (length body) (+ (length open) (length close)))
                           (string-prefix-p open body)
                           (string-suffix-p close body)))
                    latex-to-svg-backend--ratex-delimiters))
         (macros (latex-to-svg-backend--ratex-one-line
                  latex-to-svg-backend-ratex-macros)))
    (when delimiter
      (setq body (string-trim
                  (substring body (length (nth 0 delimiter))
                             (- (length (nth 1 delimiter)))))))
    (cons (if (string-empty-p macros) body (concat macros " " body))
          (nth 2 delimiter))))

;;;; SVG

(defconst latex-to-svg-backend--ratex-ink "#010203"
  "Color RaTeX is told to draw the default ink in.
RaTeX writes a color into every element it draws.  The engine replaces
this one with `currentColor' (see `latex-to-svg-backend--ratex-svg'),
which leaves the SVG color-independent, as dvisvgm's `--currentcolor'
does for the LaTeX engine.  A formula's own `\\color' keeps its color.")

(defconst latex-to-svg-backend--ratex-ink-svg "rgba(1,2,3,1)"
  "How RaTeX writes `latex-to-svg-backend--ratex-ink' in its SVG.")

(defun latex-to-svg-backend--ratex-attribute (tag name)
  "Return the value of attribute NAME in the SVG start TAG, or nil."
  (when (string-match (concat "[[:space:]]" (regexp-quote name)
                              "=\"\\([^\"]*\\)\"")
                      tag)
    (match-string 1 tag)))

(defun latex-to-svg-backend--ratex-ink-box (svg)
  "Return the box around the ink of RaTeX's SVG, as (X0 Y0 X1 Y1), or nil.
dvisvgm's `--exact-bbox' crops the LaTeX engine's SVGs to their ink.
RaTeX sizes its SVG from the font metrics instead, so glyph overshoot
falls outside the viewport and side bearings stay inside it.

RaTeX draws with `<path>' elements, whose coordinates are all absolute
pairs, and with `<rect>' and `<line>'.  A path's box is taken over its
control points, which bound the curve.  A stroked element's box grows
by half its `stroke-width'.  Nil when SVG has none of these elements."
  (let ((start 0) box)
    (while (string-match "<\\(path\\|rect\\|line\\)[[:space:]][^>]*>" svg start)
      (let ((tag (match-string 0 svg))
            (kind (match-string 1 svg)))
        (setq start (match-end 0))
        (let* ((attr (lambda (name)
                       (latex-to-svg-backend--ratex-attribute tag name)))
               (num (lambda (name)
                      (string-to-number (or (funcall attr name) "0"))))
               (stroke (funcall attr "stroke"))
               (grow (if (and stroke (not (equal stroke "none")))
                         (/ (funcall num "stroke-width") 2.0)
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
                         (list (funcall num "x2") (funcall num "y2")))))))
          (pcase-dolist (`(,x ,y) points)
            (when y
              (setq box
                    (if box
                        (pcase-let ((`(,x0 ,y0 ,x1 ,y1) box))
                          (list (min x0 (- x grow)) (min y0 (- y grow))
                                (max x1 (+ x grow)) (max y1 (+ y grow))))
                      (list (- x grow) (- y grow) (+ x grow) (+ y grow)))))))))
    box))

(defun latex-to-svg-backend--ratex-svg (svg)
  "Return RaTeX's SVG made color-independent and cropped to its ink, or nil.
The default ink, drawn in `latex-to-svg-backend--ratex-ink', becomes
`currentColor'.  The root element is rewritten with the viewport around
the ink (see `latex-to-svg-backend--ratex-ink-box') and in the form
dvisvgm writes it -- width and height in pt, values in single quotes --
which is the form `latex-to-svg-backend--pad-svg' reads.  One SVG unit
is one pt, as in the LaTeX engine's SVGs.  Nil when SVG has no root
element."
  (when (string-match "<svg\\b[^>]*>" svg)
    (let* ((root-beg (match-beginning 0))
           (root-end (match-end 0))
           (view-box (latex-to-svg-backend--ratex-attribute
                      (match-string 0 svg) "viewBox"))
           (box (or (latex-to-svg-backend--ratex-ink-box svg)
                    ;; Nothing drawn (`\,' alone, say): keep RaTeX's viewport.
                    (pcase-let ((`(,x ,y ,w ,h)
                                 (mapcar #'string-to-number
                                         (split-string (or view-box "0 0 0 0")))))
                      (list x y (+ x w) (+ y h))))))
      (pcase-let ((`(,x0 ,y0 ,x1 ,y1) box))
        (concat (substring svg 0 root-beg)
                (format "<svg xmlns='http://www.w3.org/2000/svg' \
width='%.4fpt' height='%.4fpt' viewBox='%.4f %.4f %.4f %.4f'>"
                        (- x1 x0) (- y1 y0) x0 y0 (- x1 x0) (- y1 y0))
                (string-replace latex-to-svg-backend--ratex-ink-svg
                                "currentColor"
                                (substring svg root-end)))))))

(defun latex-to-svg-backend--ratex-store (output svg)
  "Write RaTeX's OUTPUT file to the cache file SVG, ready for display.
See `latex-to-svg-backend--ratex-svg' for what changes.  Return non-nil
on success, nil when OUTPUT has no SVG root element."
  (when-let* ((data (latex-to-svg-backend--ratex-svg
                     (with-temp-buffer
                       (let ((coding-system-for-read 'utf-8))
                         (insert-file-contents output))
                       (buffer-string)))))
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file svg
        (insert data)))
    t))

;;;; Compile

(defun latex-to-svg-backend--ratex-compile (key latex)
  "Asynchronously render LATEX with RaTeX to the cache SVG for KEY.
The formula (see `latex-to-svg-backend--ratex-formula') is written to a
scratch directory, where `latex-to-svg-backend-ratex-program' renders it.
On success the SVG is stored in the cache (see
`latex-to-svg-backend--ratex-store') and every callback queued for KEY
is notified (see `latex-to-svg-backend--enqueue').  On failure the log is
saved and a warning emitted (see `latex-to-svg-backend--compile-failed')
and the queued callbacks are dropped.  The scratch directory is removed
either way.

RaTeX emits no compile metadata, so no `.eld' sidecar is written."
  (pcase-let* ((`(,formula . ,inline) (latex-to-svg-backend--ratex-formula latex))
               (dir (make-temp-file "latex-to-svg-backend" t))
               (input (expand-file-name "equation.txt" dir))
               ;; `render-svg' numbers its outputs, from 0001.svg.
               (output (expand-file-name "0001.svg" dir))
               (svg (latex-to-svg-backend--svg-file key))
               (output-buffer (generate-new-buffer
                               (format " *latex-to-svg-backend-%s*" key))))
    ;; Pin UTF-8, for the reason `latex-to-svg-backend--compile' gives.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file input
        (insert formula "\n")))
    (latex-to-svg-backend--run-process-chain
     dir output-buffer
     (list
      (list 'ratex
            (append
             (list latex-to-svg-backend-ratex-program
                   "--input" input
                   "--output-dir" dir
                   ;; A 40-unit font at a device pixel ratio of 1/4 is a
                   ;; 10pt em, the LaTeX engine's body font, and `--dpr'
                   ;; scales the stroke widths with it.
                   "--font-size" "40"
                   "--dpr" "0.25"
                   "--padding" "0"
                   "--color" latex-to-svg-backend--ratex-ink)
             (and inline '("--inline")))
            output))
     (lambda (success)
       (unwind-protect
           (if (and success
                    (condition-case err
                        (or (latex-to-svg-backend--ratex-store output svg)
                            (progn
                              (latex-to-svg-backend--append-process-log
                               output-buffer
                               "[ratex] output has no <svg> element")
                              nil))
                      (file-error
                       (latex-to-svg-backend--append-process-log
                        output-buffer
                        (format "[ratex] storing the SVG failed: %s"
                                (error-message-string err)))
                       nil)))
               (latex-to-svg-backend--notify-pending key)
             (latex-to-svg-backend--compile-failed
              key latex dir
              (latex-to-svg-backend--process-output output-buffer)))
         (remhash key latex-to-svg-backend--pending)
         (when (buffer-live-p output-buffer)
           (kill-buffer output-buffer))
         (delete-directory dir t))))))

(provide 'latex-to-svg-backend-ratex)

;;; latex-to-svg-backend-ratex.el ends here
