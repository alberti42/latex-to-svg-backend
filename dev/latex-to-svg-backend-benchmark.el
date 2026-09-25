;;; latex-to-svg-backend-benchmark.el --- Time the two renderers -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg-backend

;;; Commentary:
;;
;; Compiles the same equations with the LaTeX and the RaTeX renderer and
;; reports how long they take.  Each run uses a fresh temporary cache
;; directory, so every equation really compiles; the user's cache is not
;; touched.  Run it from a checkout:
;;
;;   emacs -Q -batch -L . -l dev/latex-to-svg-backend-benchmark.el \
;;         -f latex-to-svg-backend-benchmark-batch
;;
;; or, in a running Emacs with the package loaded, load this file and
;; call `M-x latex-to-svg-backend-benchmark'.  The LaTeX runs use the
;; current preamble and `latex-to-svg-backend-precompile'; the `.fmt' is
;; built before the timing starts and its build time is reported
;; separately.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'latex-to-svg-backend)

(defvar latex-to-svg-backend-benchmark-equations
  '("$x^2$"
    "$\\alpha+\\beta=\\gamma$"
    "$e^{i\\pi}+1=0$"
    "$\\sqrt{x^2+y^2}$"
    "$\\frac{a}{b}$"
    "$\\hbar\\omega$"
    "$\\langle\\psi|\\phi\\rangle$"
    "$\\nabla\\cdot\\mathbf{E}=\\rho/\\varepsilon_0$"
    "\\[\\int_0^\\infty e^{-x^2}\\,dx=\\frac{\\sqrt{\\pi}}{2}\\]"
    "\\[\\sum_{n=1}^\\infty \\frac{1}{n^2}=\\frac{\\pi^2}{6}\\]"
    "\\[\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}\\]"
    "\\[\\lim_{x\\to 0}\\frac{\\sin x}{x}=1\\]"
    "\\[\\left(\\frac{\\partial f}{\\partial x}\\right)^2\\]"
    "\\[\\binom{n}{k}=\\frac{n!}{k!(n-k)!}\\]"
    "\\[\\oint_C \\mathbf{B}\\cdot d\\mathbf{l}=\\mu_0 I\\]"
    "\\[\\det(A-\\lambda I)=0\\]"
    "\\[\\mathcal{L}=\\bar\\psi(i\\gamma^\\mu\\partial_\\mu-m)\\psi\\]"
    "\\[f(x)=\\begin{cases}1&x>0\\\\0&x\\le 0\\end{cases}\\]"
    "\\begin{equation}\nF = ma\n\\end{equation}"
    "\\begin{align}\na&=b+c\\\\\nd&=e+f\n\\end{align}")
  "Equations the benchmark compiles; both renderers accept all of them.")

(defun latex-to-svg-backend-benchmark--wait (pred timeout)
  "Process output until PRED returns non-nil or TIMEOUT seconds pass."
  (let ((end (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.005))))

(defun latex-to-svg-backend-benchmark--run (renderer mode)
  "Compile every equation with RENDERER in MODE and return the timings.
MODE `sequential' compiles one equation, waits for its callback and
starts the next; `batch' queues all of them at once, as a front-end does
for a buffer, and times until the last is done.  Everything runs inside
this function's dynamic extent, so the process sentinels see the
temporary cache directory."
  (let* ((dir (make-temp-file "l2s-bench" t))
         (latex-to-svg-backend-renderer renderer)
         (latex-to-svg-backend-cache-directory dir)
         (latex-to-svg-backend-render-on-non-graphic t)
         (latex-to-svg-backend-metadata-prefix nil)
         (latex-to-svg-backend--pending (make-hash-table :test 'equal))
         (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
         (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal))
         (pending latex-to-svg-backend--pending)
         (equations latex-to-svg-backend-benchmark-equations)
         fmt-time times (done 0) wall)
    (unwind-protect
        (progn
          (when (eq renderer 'latex)
            (let ((start (float-time)))
              (latex-to-svg-backend--ensure-format)
              (setq fmt-time (- (float-time) start))))
          (pcase mode
            ('sequential
             (dolist (equation equations)
               (let ((key (latex-to-svg-backend--cache-key equation))
                     (ok nil)
                     (start (float-time)))
                 (latex-to-svg-backend equation :callback (lambda () (setq ok t)))
                 (latex-to-svg-backend-benchmark--wait
                  (lambda () (or ok (not (gethash key pending)))) 30)
                 (when ok
                   (cl-incf done)
                   (push (- (float-time) start) times)))))
            ('batch
             (let ((keys (mapcar #'latex-to-svg-backend--cache-key equations))
                   (start (float-time)))
               (dolist (equation equations)
                 (latex-to-svg-backend equation :callback (lambda () (cl-incf done))))
               (latex-to-svg-backend-benchmark--wait
                (lambda () (seq-every-p (lambda (k) (not (gethash k pending))) keys))
                120)
               (setq wall (- (float-time) start))))))
      (delete-directory dir t))
    (list :renderer renderer :mode mode :done done :total (length equations)
          :fmt fmt-time :times (nreverse times) :wall wall)))

(defun latex-to-svg-backend-benchmark--ms (seconds)
  "Return SECONDS as whole milliseconds."
  (round (* 1000 seconds)))

(defun latex-to-svg-backend-benchmark--line (run)
  "Return one line of the report for RUN."
  (let* ((ms #'latex-to-svg-backend-benchmark--ms)
         (sorted (sort (copy-sequence (plist-get run :times)) #'<))
         (n (length sorted)))
    (format "%-5s %-10s ok %2d/%2d  %s%s"
            (plist-get run :renderer) (plist-get run :mode)
            (plist-get run :done) (plist-get run :total)
            (if-let* ((wall (plist-get run :wall)))
                (format "total %5d ms  (%d ms per equation)"
                        (funcall ms wall)
                        (funcall ms (/ wall (plist-get run :total))))
              (format "median %4d  min %4d  max %4d ms"
                      (funcall ms (nth (/ n 2) sorted))
                      (funcall ms (car sorted))
                      (funcall ms (car (last sorted)))))
            (if-let* ((fmt (plist-get run :fmt)))
                (format "  [.fmt build %d ms]" (funcall ms fmt))
              ""))))

(defun latex-to-svg-backend-benchmark-report (&optional rounds)
  "Run ROUNDS rounds (default 2) of both renderers in both modes.
Return the report as a string."
  (let (lines)
    (dotimes (_ (or rounds 2))
      (dolist (mode '(sequential batch))
        (dolist (renderer '(latex ratex))
          (push (latex-to-svg-backend-benchmark--line
                 (latex-to-svg-backend-benchmark--run renderer mode))
                lines))))
    (concat (format "Emacs %s, precompile %s, appended preamble %s\n"
                    emacs-version latex-to-svg-backend-precompile
                    (if (string-empty-p latex-to-svg-backend-appended-preamble)
                        "empty" "set"))
            (string-join (nreverse lines) "\n")
            "\n")))

;;;###autoload
(defun latex-to-svg-backend-benchmark (&optional rounds)
  "Time the LaTeX and RaTeX renderers and show the report.
ROUNDS (default 2, or the prefix argument) is how many times each
renderer runs in each mode.  Emacs is busy until it finishes."
  (interactive "P")
  (let ((report (latex-to-svg-backend-benchmark-report
                 (and rounds (prefix-numeric-value rounds)))))
    (with-current-buffer (get-buffer-create "*latex-to-svg-backend-benchmark*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert report))
      (display-buffer (current-buffer)))
    report))

(defun latex-to-svg-backend-benchmark-batch ()
  "Print the report to standard output, for `emacs -batch'."
  (princ (latex-to-svg-backend-benchmark-report)))

(provide 'latex-to-svg-backend-benchmark)

;;; latex-to-svg-backend-benchmark.el ends here
