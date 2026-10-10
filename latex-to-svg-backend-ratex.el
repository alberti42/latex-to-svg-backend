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

(defun latex-to-svg-backend--ratex-inputs ()
  "Return what the RaTeX engine reads from the current buffer, as a plist.
That is `(:ratex-macros MACROS)', the value of
`latex-to-svg-backend-ratex-macros'.  A request reads it once, in the
buffer that makes it, and passes it on: a fallback to RaTeX starts from
the process sentinel, where the current buffer is another."
  (list :ratex-macros latex-to-svg-backend-ratex-macros))

(defun latex-to-svg-backend--ratex-cache-salt (inputs)
  "Return the text the RaTeX engine folds into the cache key.
INPUTS is as for `latex-to-svg-backend--ratex-inputs'.  The engine's
name keeps its SVGs apart from the LaTeX engine's, and the macros are
part of every formula."
  (concat "ratex\0" (plist-get inputs :ratex-macros)))

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

(defun latex-to-svg-backend--ratex-formula (latex &optional macros)
  "Return (FORMULA . INLINE) for rendering LATEX with RaTeX.
FORMULA is LATEX on one line (see `latex-to-svg-backend--ratex-one-line')
with its outer delimiter removed (see
`latex-to-svg-backend--ratex-delimiters') and MACROS in front, by
default `latex-to-svg-backend-ratex-macros'.  INLINE is non-nil when
the delimiter was an inline one."
  (let* ((body (latex-to-svg-backend--ratex-one-line latex))
         (delimiter
          (seq-find (pcase-lambda (`(,open ,close ,_))
                      (and (>= (length body) (+ (length open) (length close)))
                           (string-prefix-p open body)
                           (string-suffix-p close body)))
                    latex-to-svg-backend--ratex-delimiters))
         (macros (latex-to-svg-backend--ratex-one-line
                  (or macros latex-to-svg-backend-ratex-macros))))
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

(defconst latex-to-svg-backend--ratex-x-height 4.31
  "The x-height of RaTeX's math font, in the units of its SVGs.
RaTeX sets formulas in KaTeX's fonts, whose x-height is 0.431 em, and
writes its 10pt em as 10 units (see
`latex-to-svg-backend--ratex-compile').  It has no preamble, so the
value does not change.")

(defconst latex-to-svg-backend--ratex-strut
  "\\vphantom{\\rule[-200pt]{0pt}{400pt}}"
  "An invisible strut appended to an inline formula.
It makes the formula's box reach 200pt above and below the baseline,
so the baseline is at the middle of the SVG RaTeX writes: RaTeX
reports no height or depth of its own.  It draws nothing and has no
width, and `latex-to-svg-backend--crop-to-ink' removes the space it
adds.  A formula taller than 200pt above or below the baseline would
move the baseline; 200pt is 20 em.")

(defun latex-to-svg-backend--ratex-svg (svg)
  "Return RaTeX's SVG made color-independent and cropped to its ink, or nil.
See `latex-to-svg-backend--crop-to-ink'; the default ink is drawn in
`latex-to-svg-backend--ratex-ink'.  RaTeX sizes its SVG from the font
metrics, so glyph overshoot falls outside the viewport and side
bearings stay inside it, until the crop."
  (latex-to-svg-backend--crop-to-ink
   svg (regexp-quote latex-to-svg-backend--ratex-ink-svg)))

(defun latex-to-svg-backend--ratex-store (output svg &optional inline)
  "Write RaTeX's OUTPUT file to the cache file SVG, ready for display.
See `latex-to-svg-backend--ratex-svg' for what changes.  INLINE non-nil
means the formula carries `latex-to-svg-backend--ratex-strut', so the
baseline is at the middle of OUTPUT's viewport, and the SVG gives it
\(see `latex-to-svg-backend--baseline-comment').  The SVG gives the
x-height of RaTeX's font too (`latex-to-svg-backend--ratex-x-height').
Return non-nil on success, nil when OUTPUT has no SVG root element."
  (when-let* ((raw (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (insert-file-contents output))
                     (buffer-string)))
              (data (latex-to-svg-backend--ratex-svg raw)))
    (let ((coding-system-for-write 'utf-8-unix)
          (geometry (and inline (latex-to-svg-backend--svg-geometry raw))))
      (with-temp-file svg
        (insert (latex-to-svg-backend--mark-x-height
                 (latex-to-svg-backend--mark-baseline
                  data (and geometry
                            (+ (nth 3 geometry) (/ (nth 5 geometry) 2.0))))
                 latex-to-svg-backend--ratex-x-height))))
    t))

;;;; Compile

(defun latex-to-svg-backend--ratex-formula-error-p (exit output)
  "Return non-nil when RaTeX rejected the formula.
EXIT is the failed stage and its exit status, as
`latex-to-svg-backend--run-process-chain' reports it, and OUTPUT is what
`render-svg' printed.  A formula RaTeX cannot parse exits with status 1
and prints \"ERR <n> <formula> — Parse error: ...\"; a disk problem
prints \"Failed to write SVG\" instead, and a panic aborts."
  (and (equal exit '(ratex . 1))
       (string-match-p "^ERR .* Parse error: " output)))

(defun latex-to-svg-backend--ratex-compile (key latex &optional inputs)
  "Asynchronously render LATEX with RaTeX to the cache SVG for KEY.
INPUTS is the plist of `latex-to-svg-backend--ratex-inputs', nil
meaning the current buffer's.
The formula (see `latex-to-svg-backend--ratex-formula') is written to a
scratch directory, where `latex-to-svg-backend-ratex-program' renders it.
On success the SVG is stored in the cache (see
`latex-to-svg-backend--ratex-store') and every callback queued for KEY
is notified (see `latex-to-svg-backend--enqueue').  On failure the
failure is handled (see `latex-to-svg-backend--compile-failed'): the log
is saved, and when RaTeX could not parse the formula (see
`latex-to-svg-backend--ratex-formula-error-p') the failure is recorded.
The scratch directory is removed either way.

RaTeX emits no compile metadata, so no `.eld' sidecar is written."
  (pcase-let* ((`(,formula . ,inline)
                (latex-to-svg-backend--ratex-formula
                 latex (plist-get (or inputs (latex-to-svg-backend--ratex-inputs))
                                  :ratex-macros)))
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
        ;; An inline formula gets the strut that puts its baseline at
        ;; the middle of the SVG.
        (insert formula
                (if inline (concat " " latex-to-svg-backend--ratex-strut) "")
                "\n")))
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
     (lambda (success &optional exit)
       (unwind-protect
           (if (and success
                    (condition-case err
                        (or (latex-to-svg-backend--ratex-store output svg inline)
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
             (let ((output (latex-to-svg-backend--process-output output-buffer)))
               (latex-to-svg-backend--compile-failed
                key latex dir output 'ratex
                (latex-to-svg-backend--ratex-formula-error-p exit output)
                exit)))
         (latex-to-svg-backend--compile-done key)
         (when (buffer-live-p output-buffer)
           (kill-buffer output-buffer))
         (delete-directory dir t))))))

(provide 'latex-to-svg-backend-ratex)

;;; latex-to-svg-backend-ratex.el ends here
