;;; latex-to-svg-backend-tests.el --- Tests for latex-to-svg-backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg-backend

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/latex-to-svg-backend-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; These exercise the rendering backend in isolation — no external TeX
;; toolchain and no graphical display are required (the graphical inputs
;; are stubbed where needed).

;;; Code:

(require 'cl-lib)
(require 'ert)
;; `display-warning' is autoloaded, and `cl-letf' resolving that autoload
;; loads warnings.el, which redefines it -- clobbering a stub installed in the
;; same `cl-letf'.  Load it up front so stubbing it is deterministic.
(require 'warnings)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

(require 'latex-to-svg-backend)
(require 'lisp-mnt)

;;;; Version

(ert-deftest latex-to-svg-backend-version-matches-the-header ()
  ;; The constant a front-end reads is the `Version:' header, so a
  ;; release that bumps one and not the other fails here.
  (should (equal latex-to-svg-backend-version
                 (lm-version (locate-library "latex-to-svg-backend.el" t)))))

(ert-deftest latex-to-svg-backend-changelog-matches-the-header ()
  ;; The CHANGELOG's newest version is the `Version:' header, so a
  ;; release that bumps one and not the other fails here.
  (let ((header (lm-version (locate-library "latex-to-svg-backend.el" t))))
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "CHANGELOG.md"
                         (file-name-directory
                          (locate-library "latex-to-svg-backend.el" t))))
      (should (re-search-forward "^## \\[\\([0-9.]+\\)\\]" nil t))
      (should (equal header (match-string 1))))))

;;;; Cache key

(ert-deftest latex-to-svg-backend-cache-key-distinguishes-inputs ()
  ;; The content key must be stable for identical inputs and differ when the
  ;; equation changes — otherwise cached SVGs collide or never hit.  Neither
  ;; display size NOR color is part of this key: the on-disk SVG is font- and
  ;; color-independent (compiled with --currentcolor, tinted at display).
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (should (equal base (latex-to-svg-backend--cache-key "E=mc^2")))
    (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^3")))))

(ert-deftest latex-to-svg-backend-cache-key-folds-in-preamble ()
  ;; Changing the preamble must invalidate the cache (different output).
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (let ((latex-to-svg-backend-preamble-base "\\documentclass{minimal}"))
      (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-backend-cache-key-folds-in-preamble-packages ()
  ;; Changing the preamble packages must also invalidate the cache.
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (let ((latex-to-svg-backend-preamble-packages "\\usepackage{braket}"))
      (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-backend-cache-key-folds-in-line-width ()
  ;; Changing the equation max width must invalidate the cache: it changes
  ;; the preamble (a `\sa@width' override), hence the render.
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (let ((latex-to-svg-backend-line-width "20cm"))
      (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-backend-cache-key-distinguishes-delimiters ()
  ;; The backend renders LATEX verbatim, so inline vs display (different
  ;; delimiters) are simply different strings and get distinct keys with no
  ;; special-casing — a `$x$' image never collides with a `\[x\]' one.
  (should-not (equal (latex-to-svg-backend--cache-key "$x$")
                     (latex-to-svg-backend--cache-key "\\[x\\]")))
  ;; And an injected \setcounter (equation numbering) folds in for free,
  ;; since it is part of the verbatim body string.
  (should-not
   (equal (latex-to-svg-backend--cache-key "\\begin{equation}x\\end{equation}")
          (latex-to-svg-backend--cache-key
           "\\setcounter{equation}{2}\\begin{equation}x\\end{equation}"))))

;;;; Cache directory

(ert-deftest latex-to-svg-backend-cache-dir-uses-xdg-default ()
  ;; With no explicit override, the cache lives under $XDG_CACHE_HOME in an
  ;; `emacs/latex-to-svg/' subdirectory, and is created on demand.
  (let* ((parent (make-temp-file "l2s-xdg" t))
         (latex-to-svg-backend-cache-directory nil)
         (process-environment (cons (concat "XDG_CACHE_HOME=" parent)
                                    process-environment)))
    (unwind-protect
        (let ((dir (latex-to-svg-backend--cache-dir)))
          (should (equal (file-name-as-directory dir)
                         (file-name-as-directory
                          (expand-file-name "emacs/latex-to-svg" parent))))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

(ert-deftest latex-to-svg-backend-cache-dir-honors-explicit-override ()
  ;; An explicit `latex-to-svg-backend-cache-directory' wins over the default and is
  ;; created on demand.
  (let* ((parent (make-temp-file "l2s-cache-override" t))
         (dir (file-name-concat parent "eqs"))
         (latex-to-svg-backend-cache-directory dir))
    (unwind-protect
        (progn
          (should (equal (latex-to-svg-backend--cache-dir) dir))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

;;;; Capability

(ert-deftest latex-to-svg-backend-available-p-is-the-svg-build-support ()
  ;; It depends on the build only: no frame is consulted.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
            ((symbol-function 'image-type-available-p)
             (lambda (type) (eq type 'svg))))
    (should (latex-to-svg-backend-available-p)))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'image-type-available-p) #'ignore))
    (should-not (latex-to-svg-backend-available-p))))

(ert-deftest latex-to-svg-backend-warns-once-of-the-obsolete-option ()
  ;; `-render-on-non-graphic' has no effect since 0.14.0, and the feature
  ;; is no longer supported; set, it is reported once per buffer, and a
  ;; request still goes ahead.
  (let ((warnings nil))
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'ignore)
              ((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (with-suppressed-warnings
          ((obsolete latex-to-svg-backend-render-on-non-graphic))
        (let ((latex-to-svg-backend-render-on-non-graphic nil))
          (latex-to-svg-backend "$x$")
          (should-not (seq-some (lambda (m) (string-search "obsolete" m))
                                warnings)))
        (let ((latex-to-svg-backend-render-on-non-graphic t))
          (with-temp-buffer
            (latex-to-svg-backend "$x$")
            (latex-to-svg-backend "$y$"))
          (should (= 1 (seq-count (lambda (m) (string-search "obsolete" m))
                                  warnings)))
          (with-temp-buffer
            (latex-to-svg-backend "$x$"))))
      (should (= 2 (seq-count (lambda (m) (string-search "obsolete" m))
                              warnings)))
      ;; It asks for the workflow that needs it.
      (should (seq-some (lambda (m)
                          (string-search
                           "github.com/alberti42/latex-to-svg-backend/issues" m))
                        warnings)))))

(ert-deftest latex-to-svg-backend-warns-once-of-svg-dpi ()
  ;; `-svg-dpi' has no effect since 0.14.0: a value other than its default
  ;; is reported once per buffer.
  (let ((warnings nil))
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'ignore)
              ((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (with-suppressed-warnings ((obsolete latex-to-svg-backend-svg-dpi))
        (latex-to-svg-backend "$x$")
        (should-not (seq-some (lambda (m) (string-search "svg-dpi" m)) warnings))
        (let ((latex-to-svg-backend-svg-dpi 144.0))
          (with-temp-buffer
            (latex-to-svg-backend "$x$")
            (latex-to-svg-backend "$y$"))
          (should (= 1 (seq-count (lambda (m) (string-search "svg-dpi" m))
                                  warnings)))
          (with-temp-buffer
            (latex-to-svg-backend "$x$"))))
      (should (= 2 (seq-count (lambda (m) (string-search "svg-dpi" m))
                              warnings))))))

;;;; Scale

(ert-deftest latex-to-svg-backend-target-x-height-nil-when-unknown ()
  ;; No X-HEIGHT means the buffer is shown nowhere: there is no size,
  ;; whatever RESCALE-BY, and no frame is measured -- not even a graphical
  ;; selected one.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'default-font-height) (lambda (&rest _) 20)))
    (should-not (latex-to-svg-backend--target-x-height nil))
    (should-not (latex-to-svg-backend--target-x-height nil 1.3))))

(ert-deftest latex-to-svg-backend-target-x-height-scales ()
  ;; The equation's font is displayed with the text's x-height times
  ;; font-scale and RESCALE-BY.  Nothing is measured, and the obsolete
  ;; `-svg-dpi' does not enter.
  (let ((latex-to-svg-backend-font-scale 1.0))
    (should (= (latex-to-svg-backend--target-x-height 10) 10))
    (with-suppressed-warnings ((obsolete latex-to-svg-backend-svg-dpi))
      (let ((latex-to-svg-backend-svg-dpi 144.0))
        (should (= (latex-to-svg-backend--target-x-height 10) 10))))
    (should (= (latex-to-svg-backend--target-x-height 10 1.5) 15)))
  (let ((latex-to-svg-backend-font-scale 2.0))
    (should (= (latex-to-svg-backend--target-x-height 10) 20))))

(ert-deftest latex-to-svg-backend-x-height-comment-round-trips ()
  ;; Written by the store steps, or by dvisvgm with TeX's unit.
  (should (equal (latex-to-svg-backend--svg-x-height
                  (latex-to-svg-backend--mark-x-height "<svg width='1pt'></svg>" 4.31))
                 4.31))
  (should (equal (latex-to-svg-backend--svg-x-height
                  "<svg><!--latex-to-svg-backend-x-height 4.28932pt--></svg>")
                 4.28932))
  (should-not (latex-to-svg-backend--svg-x-height "<svg width='1pt'></svg>"))
  (should-not (latex-to-svg-backend--svg-x-height
               "<svg><!--latex-to-svg-backend-x-height 0.0pt--></svg>")))

(ert-deftest latex-to-svg-backend-image-width-is-the-width-property ()
  ;; Every image the backend returns has `:width' in pixels at `:scale' 1.0,
  ;; which is its displayed width.
  (should (equal (latex-to-svg-backend-image-width
                  (list 'image :type 'svg :scale 1.0 :width 30 :data "<svg/>"))
                 30))
  (should-not (latex-to-svg-backend-image-width
               (list 'image :type 'svg :data "<svg/>")))
  (should-not (latex-to-svg-backend-image-width 'not-an-image)))

(ert-deftest latex-to-svg-backend-load-svg-sizes-by-width ()
  ;; The image is the SVG's width times X-HEIGHT over the x-height the SVG
  ;; gives for its font, rounded, at `:scale' 1.0, so
  ;; `image-scaling-factor' does not apply.
  ;; The padding is included.  Needs an Emacs built with librsvg, as the
  ;; `--load-svg-image' tests below.
  (skip-unless (image-type-available-p 'svg))
  (let ((tmp (make-temp-file "l2s-width-pad" nil ".svg")))
    (unwind-protect
        (progn
          ;; The font's x-height is 2pt, so an x-height of 4px is 2px/pt.
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='10pt' height='5pt' viewBox='0 0 10 5'>"
                    "<!--latex-to-svg-backend-x-height 2.000000-->"
                    "<path fill='currentColor' d='M0 0h1v1z'/></svg>"))
          (let ((image (latex-to-svg-backend--load-svg-image tmp 4.0 "#000")))
            (should (equal (image-property image :width) 20))
            (should (equal (image-property image :scale) 1.0)))
          ;; (10 + 2 right + 4 left) pt * 2.0 px/pt = 32 px.
          (should (equal (latex-to-svg-backend-image-width
                          (latex-to-svg-backend--load-svg-image
                           tmp 4.0 "#000" nil '(1 2 3 4)))
                         32))
          (should (equal (image-property
                          (latex-to-svg-backend--load-svg-image tmp 2.08 "#000")
                          :width)
                         10)))
      (delete-file tmp))))

;;;; Baseline

(ert-deftest latex-to-svg-backend-ascent-puts-the-baseline-on-the-line ()
  ;; The ascent is the share of the image above the baseline the SVG gives,
  ;; in percent, kept within 0..100; with no baseline, as for a display
  ;; equation, the image is centred.
  (let ((svg (lambda (y top height)
               (latex-to-svg-backend--mark-baseline
                (format "<svg xmlns='http://www.w3.org/2000/svg' width='10pt' \
height='%spt' viewBox='0 %s 10 %s'><path d='M0 0'/></svg>" height top height)
                y))))
    (should (equal (latex-to-svg-backend--ascent (funcall svg 8 0 10)) 80))
    (should (equal (latex-to-svg-backend--ascent (funcall svg -62.5 -70 10)) 75))
    ;; All the ink below the baseline, or above it.
    (should (equal (latex-to-svg-backend--ascent (funcall svg -1 0 10)) 0))
    (should (equal (latex-to-svg-backend--ascent (funcall svg 12 0 10)) 100))
    (should (eq (latex-to-svg-backend--ascent (funcall svg nil 0 10)) 'center))
    ;; Padding moves the viewport, not the baseline: 2pt on top and bottom
    ;; of a 10pt image with the baseline 8pt down make it 10/14 above.
    (should (equal (latex-to-svg-backend--ascent
                    (latex-to-svg-backend--pad-svg (funcall svg 8 0 10)
                                                   '(2 0) nil))
                   71))))

(ert-deftest latex-to-svg-backend-baseline-comment-round-trips ()
  (should (equal (latex-to-svg-backend--svg-baseline
                  (latex-to-svg-backend--mark-baseline "<svg width='1pt'></svg>" -61.897857))
                 -61.897857))
  (should-not (latex-to-svg-backend--svg-baseline "<svg width='1pt'></svg>"))
  ;; As dvisvgm writes it, from the special of the LaTeX engine.
  (should (equal (latex-to-svg-backend--svg-baseline
                  "<svg><g><!--latex-to-svg-backend-baseline -65.71802--></g></svg>")
                 -65.71802)))

;;;; Colors

(ert-deftest latex-to-svg-backend-hex-color-accepts-only-rrggbb ()
  ;; The backend resolves no color names: a name resolves on a frame, and
  ;; the backend does not know which one shows the buffer.
  (should-not (latex-to-svg-backend--hex-color nil :color))
  (should (equal (latex-to-svg-backend--hex-color "#1a2B3c" :color) "#1a2B3c"))
  (dolist (color '("grey50" "#fff" "#ffffffffffff" "#12345g" "" red))
    (should-error (latex-to-svg-backend--hex-color color :color))))

(ert-deftest latex-to-svg-backend-requires-a-hex-color ()
  ;; Checked before anything else, so a caller bug signals whether or not
  ;; the equation is cached or renderable.
  (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () nil))
            ((symbol-function 'display-warning) #'ignore))
    (should-error (latex-to-svg-backend "$x$" :x-height 10))
    (should-error (latex-to-svg-backend "$x$" :x-height 10 :color "grey50"))
    (should-error (latex-to-svg-backend "$x$" :color "#000000" :background "gray97"))
    (should-not (latex-to-svg-backend "$x$" :x-height 10 :color "#000000"
                                      :background "#f7f7f7"))
    ;; No x-height: the buffer is shown nowhere, no image is built, so no
    ;; color is needed.
    (should-not (latex-to-svg-backend "$x$"))
    ;; A size is a positive number of pixels, and the keyword of 0.13.0
    ;; is gone.
    (should-error (latex-to-svg-backend "$x$" :x-height 0 :color "#000000"))
    (should-error (latex-to-svg-backend "$x$" :x-height "10" :color "#000000"))
    (should-error (latex-to-svg-backend "$x$" :font-height 20 :color "#000000"))
    (should-error (latex-to-svg-backend "$x$" :font-size 18 :color "#000000"))))

;;;; Image cache

(ert-deftest latex-to-svg-backend-image-cache-key-includes-scale-and-color ()
  ;; The in-memory image-cache key folds in BOTH the display scale and the
  ;; tint color, so the same equation at two font sizes or two themes maps
  ;; to distinct entries (the on-disk SVG is shared).
  (should (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                 (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")))
  (should-not (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg-backend--image-cache-key "K" 1.5 "#fff")))
  (should-not (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg-backend--image-cache-key "K" 0.8 "#000")))
  ;; Background is a distinct dimension too: a boxed variant of the same
  ;; equation coexists with the transparent one (nil background).
  (should-not (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff" "#eee"))))

(ert-deftest latex-to-svg-backend-load-svg-recolors-currentcolor ()
  ;; The on-disk SVG carries `currentColor'; loading substitutes the given
  ;; foreground in, so the image is tinted without recompiling.
  ;; `create-image' signals "Invalid image type" on an Emacs built without
  ;; librsvg -- a minimal CI build is one, so this and the two tests below
  ;; skip there rather than reporting the build as a failure.
  (skip-unless (image-type-available-p 'svg))
  (let ((tmp (make-temp-file "l2s-cc" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='1pt' height='1pt' viewBox='0 0 1 1'>"
                    "<!--latex-to-svg-backend-x-height 1.000000-->"
                    "<path fill='currentColor' d='M0 0h1v1z'/></svg>"))
          (let ((data (image-property
                       (latex-to-svg-backend--load-svg-image tmp 1.0 "#abcdef")
                       :data)))
            (should (string-match-p "#abcdef" data))
            (should-not (string-match-p "currentColor" data))))
      (delete-file tmp))))

(ert-deftest latex-to-svg-backend-load-svg-paints-background ()
  ;; BACKGROUND is applied post-generation as `create-image' `:background'
  ;; (the SVG stays transparent on disk); nil leaves the image transparent.
  (skip-unless (image-type-available-p 'svg))
  (let ((tmp (make-temp-file "l2s-bg" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='1pt' height='1pt' viewBox='0 0 1 1'>"
                    "<!--latex-to-svg-backend-x-height 1.000000-->"
                    "<path fill='currentColor' d='M0 0h1v1z'/></svg>"))
          (should-not (image-property
                       (latex-to-svg-backend--load-svg-image tmp 1.0 "#000")
                       :background))
          (should (equal (image-property
                          (latex-to-svg-backend--load-svg-image tmp 1.0 "#000" "#eeeeee")
                          :background)
                         "#eeeeee")))
      (delete-file tmp))))

(ert-deftest latex-to-svg-backend-pad-box-normalizes-css-order ()
  ;; A number pads all four sides; a list of 1-4 numbers is read in CSS
  ;; order, so a left-only gutter is expressible.  All-zero and nil mean
  ;; "nothing to pad" (nil), and the function is idempotent on its output
  ;; so one spec can be normalized at the key and again at the geometry.
  (should (equal (latex-to-svg-backend--pad-box 3) '(3 3 3 3)))
  (should (equal (latex-to-svg-backend--pad-box '(3)) '(3 3 3 3)))
  (should (equal (latex-to-svg-backend--pad-box '(1 2)) '(1 2 1 2)))
  (should (equal (latex-to-svg-backend--pad-box '(1 2 3)) '(1 2 3 2)))
  (should (equal (latex-to-svg-backend--pad-box '(1 2 3 4)) '(1 2 3 4)))
  (should (equal (latex-to-svg-backend--pad-box '(0 0 0 6)) '(0 0 0 6)))
  (should-not (latex-to-svg-backend--pad-box nil))
  (should-not (latex-to-svg-backend--pad-box 0))
  (should-not (latex-to-svg-backend--pad-box '(0 0 0 0)))
  (should (equal (latex-to-svg-backend--pad-box
                  (latex-to-svg-backend--pad-box '(1 2)))
                 '(1 2 1 2)))
  ;; A malformed spec is a caller bug: signal rather than silently drop the
  ;; padding and draw a box that merely looks wrong.
  (should-error (latex-to-svg-backend--pad-box '(1 2 3 4 5)))
  (should-error (latex-to-svg-backend--pad-box '(1 "2")))
  (should-error (latex-to-svg-backend--pad-box "3"))
  (should-error (latex-to-svg-backend--pad-box '(0 0 0 -6))))

(ert-deftest latex-to-svg-backend-pad-svg-grows-viewport-and-boxes ()
  ;; Padding grows the root <svg> width/height/viewBox by 2*PAD and, with a
  ;; background, injects a filled <rect> covering the padded viewport behind
  ;; the content.  The color is then baked into the SVG (not create-image's
  ;; :background), so it extends PAD beyond the ink.
  (let* ((svg (concat "<svg version='1.1' xmlns='http://www.w3.org/2000/svg' "
                      "width='36pt' height='14pt' "
                      "viewBox='-69 -70 36 14'>"
                      "<path fill='#000' d='M0 0h1v1z'/></svg>"))
         (out (latex-to-svg-backend--pad-svg svg 3 "#eeeeee")))
    ;; Viewport grown by 2*PAD = 6 on each dimension, origin shifted by -PAD.
    (should (string-match-p "width='42pt'" out))
    (should (string-match-p "height='20pt'" out))
    (should (string-match-p "viewBox='-72 -73 42 20'" out))
    ;; A background rect covering the padded viewport, before the content.
    (should (string-match-p
             "<rect x='-72' y='-73' width='42' height='20' fill='#eeeeee'/>" out))
    (should (< (string-match "<rect" out) (string-match "<path" out)))
    ;; No rect without a background; PAD 0 is a no-op.
    (should-not (string-match-p "<rect" (latex-to-svg-backend--pad-svg svg 3 nil)))
    (should (equal (latex-to-svg-backend--pad-svg svg 0 "#eee") svg))))

(ert-deftest latex-to-svg-backend-pad-svg-pads-each-side-separately ()
  ;; Per-side padding: each dimension grows by the sum of its two sides and
  ;; the origin shifts by the left/top ones only -- so (0 0 0 6) is a left
  ;; gutter, with the ink left where it was relative to the right edge.
  (let* ((svg (concat "<svg version='1.1' xmlns='http://www.w3.org/2000/svg' "
                      "width='36pt' height='14pt' "
                      "viewBox='-69 -70 36 14'>"
                      "<path fill='#000' d='M0 0h1v1z'/></svg>"))
         (out (latex-to-svg-backend--pad-svg svg '(1 2 3 4) "#eeeeee")))
    ;; width += left+right = 6, height += top+bottom = 4.
    (should (string-match-p "width='42pt'" out))
    (should (string-match-p "height='18pt'" out))
    ;; Origin shifts by -left / -top only.
    (should (string-match-p "viewBox='-73 -71 42 18'" out))
    (should (string-match-p
             "<rect x='-73' y='-71' width='42' height='18' fill='#eeeeee'/>" out))
    ;; A left-only gutter grows the width and moves the origin left; the
    ;; height and the vertical origin are untouched.
    (let ((left (latex-to-svg-backend--pad-svg svg '(0 0 0 6) nil)))
      (should (string-match-p "width='42pt'" left))
      (should (string-match-p "height='14pt'" left))
      (should (string-match-p "viewBox='-75 -70 42 14'" left)))))

(ert-deftest latex-to-svg-backend-svg-attribute-reads-either-quote ()
  ;; dvisvgm writes single quotes, svg.el double ones; `stroke-width' is
  ;; not `width'.  Setting an attribute keeps its quotes.
  (let ((single "<svg stroke-width='9' width='36pt' viewBox='0 0 36 14'>")
        (double "<svg width=\"40\" height=\"20\">"))
    (should (equal (latex-to-svg-backend--svg-attribute single "width") "36pt"))
    (should (equal (latex-to-svg-backend--svg-attribute double "width") "40"))
    (should-not (latex-to-svg-backend--svg-attribute double "viewBox"))
    (should (equal (latex-to-svg-backend--svg-set-attribute single "width" "42pt")
                   "<svg stroke-width='9' width='42pt' viewBox='0 0 36 14'>"))
    (should (equal (latex-to-svg-backend--svg-set-attribute double "height" "8")
                   "<svg width=\"40\" height=\"8\">"))
    (should (equal (latex-to-svg-backend--svg-set-attribute double "viewBox" "x")
                   double)))
  (should (equal (latex-to-svg-backend--svg-root "<?xml?>\n<svg a='1'><g/></svg>")
                 '(8 . 19)))
  (should-not (latex-to-svg-backend--svg-root "<g/>")))

(ert-deftest latex-to-svg-backend-image-cache-key-includes-padding ()
  ;; Padding is its own cache dimension, so a padded box coexists with an
  ;; unpadded one of the same equation / size / colors -- and two paddings
  ;; that differ only in which side they grow are distinct entries.
  (should-not (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff" "#eee")
                     (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff" "#eee" 3)))
  (should-not (equal (latex-to-svg-backend--image-cache-key
                      "K" 0.8 "#fff" "#eee" '(0 0 0 6))
                     (latex-to-svg-backend--image-cache-key
                      "K" 0.8 "#fff" "#eee" '(6 0 0 0))))
  ;; Normalized first (as `--cached-image' does), a number and its four-side
  ;; spelling are one entry, not two.
  (should (equal (latex-to-svg-backend--image-cache-key
                  "K" 0.8 "#fff" "#eee" (latex-to-svg-backend--pad-box 6))
                 (latex-to-svg-backend--image-cache-key
                  "K" 0.8 "#fff" "#eee"
                  (latex-to-svg-backend--pad-box '(6 6 6 6))))))

(ert-deftest latex-to-svg-backend-image-cache-coexists-per-size ()
  ;; The same on-disk SVG cached at two font sizes yields two distinct
  ;; image objects that coexist: the first stays warm after the second is
  ;; created (so a sibling buffer's images survive a font change — no clear).
  (skip-unless (image-type-available-p 'svg))
  (let ((tmp (make-temp-file "l2s-svg" nil ".svg"))
        (latex-to-svg-backend-font-scale 1.0))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='4.31pt' height='4.31pt' "
                    "viewBox='0 0 4.31 4.31'>"
                    "<!--latex-to-svg-backend-x-height 4.310000-->"
                    "<rect width='10' height='10'/></svg>"))
          (clrhash latex-to-svg-backend--image-cache)
          (cl-letf (((symbol-function 'latex-to-svg-backend--svg-file)
                     (lambda (_key) tmp)))
            (let ((img1 (latex-to-svg-backend--cached-image
                         "K" nil "#000000" nil nil 18))
                  (img2 (latex-to-svg-backend--cached-image
                         "K" nil "#000000" nil nil 24)))
              (should img1)
              (should img2)
              ;; Two coexisting entries, one per size.
              (should (= 2 (hash-table-count latex-to-svg-backend--image-cache)))
              ;; The first is still served from cache (warm, not evicted).
              (should (eq img1 (latex-to-svg-backend--cached-image
                                "K" nil "#000000" nil nil 18)))
              ;; An SVG one x-height wide is X-HEIGHT pixels wide.
              (should (equal (image-property img1 :width) 18))
              (should (equal (image-property img2 :width) 24))
              ;; RESCALE-BY is a size of its own.
              (should (equal (image-property
                              (latex-to-svg-backend--cached-image
                               "K" 1.5 "#000000" nil nil 18)
                              :width)
                             27)))))
      (delete-file tmp))))

(ert-deftest latex-to-svg-backend-failed-dump-waits-for-a-change ()
  ;; A failed dump writes a stamp marked failed: no dump and no warning
  ;; until a file it names changes, also in a new session.  Each dump
  ;; that fails warns.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-failed" t))
         (latex-to-svg-backend-precompile t)
         (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
         (binary (make-temp-file "l2s-bin"))
         (base (make-temp-file "l2s-latex" nil ".fmt"))
         (preamble (latex-to-svg-backend--preamble))
         (fkey (latex-to-svg-backend--format-key preamble))
         (fmt (latex-to-svg-backend--format-file fkey))
         (log (concat (file-name-sans-extension fmt) ".log"))
         (failed (cons 'failed log))
         (rv 1)
         (dumps 0)
         (warnings nil))
    (set-file-times base '(1 0))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                   (lambda (&optional _program) binary))
                  ;; TeX writes the log and the `-recorder' list also when
                  ;; the dump fails.
                  ((symbol-function 'call-process)
                   (lambda (&rest _)
                     (cl-incf dumps)
                     (with-temp-file log (insert "! Undefined control sequence.\n"))
                     (with-temp-file (concat (file-name-sans-extension fmt) ".fls")
                       (insert "INPUT " base "\n"))
                     (when (eql rv 0)
                       (with-temp-file fmt (insert "fmt")))
                     rv))
                  ((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (with-temp-buffer
            (dotimes (_ 3)
              (should (equal (latex-to-svg-backend--ensure-format preamble)
                             failed)))
            (should (= dumps 1))
            (should (= (length warnings) 1))
            (should (string-search log (car warnings)))
            (should-not (file-exists-p fmt))
            (should (file-exists-p log))
            ;; The stamp says the dump failed; its log is found from its name.
            (should (eq (plist-get (latex-to-svg-backend--read-format-stamp fmt)
                                   :failed)
                        t))
            ;; A new session reads the stamp: no dump, no warning.
            (clrhash latex-to-svg-backend--format-stamps)
            (should (equal (latex-to-svg-backend--ensure-format preamble) failed))
            (should (= dumps 1))
            (should (= (length warnings) 1))
            ;; An edit of a listed package file dumps again, and warns again.
            (let ((files '(("/p/macros.tex" 2 . 0))))
              (should (equal (latex-to-svg-backend--ensure-format
                              preamble nil files)
                             failed))
              (should (= dumps 2))
              (should (= (length warnings) 2))
              ;; So does an update of the distribution's `.fmt' file, and a
              ;; dump that succeeds ends it.
              (set-file-times base '(2 0))
              (setq rv 0)
              (should (equal (latex-to-svg-backend--ensure-format
                              preamble nil files)
                             fmt))
              (should (= dumps 3))
              (should (= (length warnings) 2))
              (should-not (file-exists-p log))
              (should-not (plist-get (latex-to-svg-backend--read-format-stamp fmt)
                                     :failed)))))
      (delete-file binary)
      (delete-file base)
      (delete-directory latex-to-svg-backend-cache-directory t))))
(ert-deftest latex-to-svg-backend-build-format-reports-unstartable-latex ()
  ;; A LaTeX program that is found but cannot be started is reported once
  ;; per buffer;
  ;; the dump still yields nil so the caller falls back to a full compile.
  ;; One that is not found signals `file-missing', for `--ensure-format'
  ;; (see `latex-to-svg-backend-missing-tex-program-writes-no-stamp').
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-err" t))
        (warnings 0)
        (err '(permission-denied "Searching for program" "Permission denied"
                                 "latex")))
    (unwind-protect
        (cl-letf (((symbol-function 'call-process)
                   (lambda (&rest _) (signal (car err) (cdr err))))
                  ((symbol-function 'display-warning)
                   (lambda (&rest _) (cl-incf warnings))))
          (setq latex-to-svg-backend--warned nil)
          (should-not (latex-to-svg-backend--build-format "deadbeef" (latex-to-svg-backend--preamble)))
          (should-not (latex-to-svg-backend--build-format "deadbeef" (latex-to-svg-backend--preamble)))
          (should (= 1 warnings))
          (setq err '(file-missing "Searching for program"
                                   "No such file or directory" "latex"))
          (should-error (latex-to-svg-backend--build-format
                         "deadbeef" (latex-to-svg-backend--preamble))
                        :type 'file-missing)
          (should-not (directory-files (latex-to-svg-backend--fmt-dir) nil "\\.tex\\'")))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;; A warning is shown once per buffer per cause, with no expiry: opening
;; the file again shows it again.
(ert-deftest latex-to-svg-backend-warn-is-once-per-buffer-per-cause ()
  (let ((warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (with-temp-buffer
        (rename-buffer "notes.org" t)
        (should (latex-to-svg-backend--warn "touching" "Cannot touch."))
        (should-not (latex-to-svg-backend--warn "touching" "Cannot touch."))
        (should (equal warnings (list (concat (buffer-name) ": Cannot touch."))))
        ;; Another cause in the same buffer is its own warning.
        (latex-to-svg-backend--warn "writing" "Cannot write.")
        (should (= 2 (length warnings))))
      ;; Another buffer is told again.
      (with-temp-buffer
        (latex-to-svg-backend--warn "touching" "Cannot touch.")
        (should (= 3 (length warnings)))))))

(ert-deftest latex-to-svg-backend-warn-does-not-expire ()
  ;; A warning that came back after a day could not be reproduced.
  (let ((warnings 0)
        (now 1000000.0))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings)))
              ((symbol-function 'float-time) (lambda (&rest _) now)))
      (with-temp-buffer
        (latex-to-svg-backend--warn "touching" "Cannot touch.")
        (setq now (+ now (* 30 86400)))
        (latex-to-svg-backend--warn "touching" "Cannot touch.")
        (should (= 1 warnings))))))

(ert-deftest latex-to-svg-backend-warn-skips-a-killed-requester ()
  ;; Work done for a killed buffer warns nowhere: nobody is looking.
  (let ((warnings 0)
        (dead (generate-new-buffer " dead")))
    (kill-buffer dead)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings))))
      (with-temp-buffer
        (latex-to-svg-backend--with-requester dead
          (latex-to-svg-backend--warn "touching" "Cannot touch."))
        (should (= 0 warnings))
        ;; A live requester is made current, and warns.
        (let ((live (current-buffer)))
          (with-temp-buffer
            (latex-to-svg-backend--with-requester live
              (should (eq (current-buffer) live))
              (latex-to-svg-backend--warn "touching" "Cannot touch."))))
        (should (= 1 warnings))
        (should (member "touching" latex-to-svg-backend--warned))))))

(ert-deftest latex-to-svg-backend-warn-waiters-warns-in-each-live-buffer ()
  ;; From a sentinel, a warning goes to the buffers that requested the
  ;; compile: each live one once, a killed one not at all.
  (let ((latex-to-svg-backend--pending (make-hash-table :test 'equal))
        (warnings nil)
        (a (generate-new-buffer "a.org"))
        (b (generate-new-buffer "b.org"))
        (dead (generate-new-buffer "dead.org")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (kill-buffer dead)
          (puthash "k" (mapcar (lambda (buffer)
                                 (with-current-buffer buffer
                                   (latex-to-svg-backend--waiter #'ignore)))
                               (list a a b))
                   latex-to-svg-backend--pending)
          (puthash "k" (cons (list :buffer dead)
                             (gethash "k" latex-to-svg-backend--pending))
                   latex-to-svg-backend--pending)
          (with-temp-buffer
            (latex-to-svg-backend--warn-waiters "k" "writing" "Cannot write."))
          (should (equal (sort warnings #'string<)
                         '("a.org: Cannot write." "b.org: Cannot write."))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest latex-to-svg-backend-touch-warns-once-when-refused ()
  ;; An unwritable cache entry (root-owned after a run under sudo, or a
  ;; read-only mount) must not break the display path -- the mtime is only a
  ;; GC hint -- but it is reported once per buffer, never silently dropped.
  (let ((warnings 0))
    (cl-letf (((symbol-function 'set-file-times)
               (lambda (&rest _)
                 (signal 'permission-denied
                         (list "Setting file times" "Permission denied"
                               "/cache/ab/cdef.svg"))))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings))))
      (with-temp-buffer
        (latex-to-svg-backend--touch "/cache/ab/cdef.svg")
        (latex-to-svg-backend--touch "/cache/ab/cdef.svg")
        (should (= 1 warnings))))))

(ert-deftest latex-to-svg-backend-touch-signals-when-file-vanished ()
  ;; `--touch' does not swallow errors: a collected entry signals
  ;; `file-missing', which the caller turns into a cache miss (next test).
  (let ((gone (make-temp-file "l2s-gone" nil ".svg")))
    (delete-file gone)
    (should-error (latex-to-svg-backend--touch gone) :type 'file-missing)))

(ert-deftest latex-to-svg-backend-cached-image-nil-when-entry-collected ()
  ;; The on-disk cache is shared across sessions, so another Emacs's GC can
  ;; remove the entry between the `file-exists-p' check and the read.  The
  ;; display path treats that as a miss (the caller recompiles) instead of
  ;; signalling; nothing is cached.
  (let ((tmp (make-temp-file "l2s-svg" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='10pt' height='10pt'>"
                    "<rect width='10' height='10'/></svg>"))
          (clrhash latex-to-svg-backend--image-cache)
          (cl-letf (((symbol-function 'latex-to-svg-backend--svg-file)
                     (lambda (_key) tmp))
                    ;; Collect the entry inside the window.
                    ((symbol-function 'latex-to-svg-backend--touch)
                     (lambda (file) (delete-file file))))
            (should-not (latex-to-svg-backend--cached-image
                         "K" nil "#000000" nil nil 18))
            (should (= 0 (hash-table-count latex-to-svg-backend--image-cache)))))
      (when (file-exists-p tmp) (delete-file tmp)))))

;;;; Public entry point

(ert-deftest latex-to-svg-backend-warns-once-without-svg-support ()
  ;; Without SVG support the entry point yields nil (the caller keeps the
  ;; LaTeX source), schedules no compile, and warns once per buffer, even
  ;; for a quiet request.
  (let ((warnings 0))
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'ignore)
              ((symbol-function 'latex-to-svg-backend--enqueue)
               (lambda (&rest _) (error "Compiled without SVG support")))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings))))
      (with-temp-buffer
        (should-not (latex-to-svg-backend "$E=mc^2$" :callback #'ignore :quiet t))
        (should-not (latex-to-svg-backend "$x$" :callback #'ignore))
        (should (= warnings 1)))
      (with-temp-buffer
        (latex-to-svg-backend "$x$" :callback #'ignore)
        (should (= warnings 2))))))

(ert-deftest latex-to-svg-backend-schedules-and-coalesces-compiles ()
  ;; Renderable, tools present, SVG not yet on disk: the entry point returns
  ;; nil, schedules ONE compile, and queues every callback for the same
  ;; content key onto it.
  (let ((latex-to-svg-backend--pending (make-hash-table :test 'equal))
        (latex-to-svg-backend--queue nil)
        (latex-to-svg-backend--running nil)
        (latex-to-svg-backend-jobs 100)
        (compiles 0))
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
              ((symbol-function 'latex-to-svg-backend--cached-image) (lambda (&rest _) nil))
              ((symbol-function 'latex-to-svg-backend--compile)
               (lambda (&rest _) (cl-incf compiles))))
      (should-not (latex-to-svg-backend "E=mc^2" :callback #'ignore))
      (should-not (latex-to-svg-backend "E=mc^2" :callback #'ignore))
      ;; Two requests for the same equation => a single in-flight compile.
      (should (= compiles 1))
      (should (= 2 (length (gethash (latex-to-svg-backend--cache-key "E=mc^2")
                                    latex-to-svg-backend--pending)))))))

(ert-deftest latex-to-svg-backend-defers-when-compiled-but-unsizable ()
  ;; SVG already on disk but no trustworthy size (--cached-image returns nil,
  ;; e.g. the buffer is shown nowhere): the entry point returns nil and does
  ;; NOT recompile — it defers to display time, when a real height exists.
  (let ((tmp (make-temp-file "l2s-defer" nil ".svg"))
        (compiles 0)
        (called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
                  ((symbol-function 'latex-to-svg-backend--svg-file) (lambda (_k) tmp))
                  ((symbol-function 'latex-to-svg-backend--cached-image) (lambda (&rest _) nil))
                  ((symbol-function 'latex-to-svg-backend--compile)
                   (lambda (&rest _) (cl-incf compiles)))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest _) (setq called t))))
          (should-not (latex-to-svg-backend
                       "E=mc^2" :callback (lambda (_) (setq called t))))
          ;; Compiled already -> no compile scheduled, and nothing pending
          ;; to call back about.
          (should (= compiles 0))
          (should-not called))
      (delete-file tmp))))

;;;; Direct process pipeline

(defun latex-to-svg-backend-tests--tex-file (process)
  "Return the absolute name of the `.tex' file fake PROCESS compiles.
The TeX program is given the file's name in its directory, where it runs."
  (expand-file-name (car (last (plist-get (aref process 3) :command)))
                    (aref process 4)))

(defun latex-to-svg-backend-tests--tex-source (file)
  "Return FILE's contents, bypassing Emacs's `.tex' coding detection.
`insert-file-contents' on a `.tex' path runs
`latexenc-find-file-coding-system' (`file-coding-system-alist'), which
signals `(wrong-type-argument stringp nil)' for a file carrying neither
`inputenc' nor a TeX-master: it reaches its master-file branch and calls
`decode-coding-string' on a nil file name.  That is an Emacs bug, not
ours -- `emacs -Q' on any such file reproduces it -- and our sources are
exactly that shape (the preamble has no `inputenc', and a `%&'-loaded
source has no preamble at all).  Binding the coding system skips the
detection.  The library never reads a `.tex' back, so only tests are
affected."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (buffer-string)))

(defun latex-to-svg-backend-tests--finish-fake-process
    (process exit-status &optional output status event)
  "Finish fake PROCESS with EXIT-STATUS, optionally appending OUTPUT.
STATUS defaults to `exit', and EVENT defaults to a status-appropriate
completion event."
  (when output
    (with-current-buffer (plist-get (aref process 3) :buffer)
      (goto-char (point-max))
      (insert output)))
  (let ((status (or status 'exit)))
    (aset process 1 status)
    (aset process 2 exit-status)
    (funcall
     (plist-get (aref process 3) :sentinel)
     process
     (or event
         (cond
          ((eq status 'signal)
           (format "killed by signal %d\n" exit-status))
          ((zerop exit-status) "finished\n")
          (t (format "exited abnormally with code %d\n" exit-status)))))))

(defmacro latex-to-svg-backend-tests--with-fake-processes (&rest body)
  "Run BODY with direct asynchronous processes captured as fake processes."
  (declare (indent 0) (debug t))
  `(let* ((l2s-test-cache-dir (make-temp-file "l2s-process-cache" t))
          (latex-to-svg-backend-cache-directory l2s-test-cache-dir)
          (latex-to-svg-backend-precompile nil)
          (latex-to-svg-backend-latex-program "latex-direct")
          (latex-to-svg-backend-dvisvgm-program "dvisvgm-direct")
          (latex-to-svg-backend--pending (make-hash-table :test 'equal))
          (latex-to-svg-backend--queue nil)
          (latex-to-svg-backend--running nil)
          (latex-to-svg-backend--processes (make-hash-table :test 'equal))
          ;; Tests leave compiles unfinished, each holding a slot: on a
          ;; machine with few processors the next one would queue.
          (latex-to-svg-backend-jobs 100)
          (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
          (l2s-test-processes nil)
          (l2s-test-missing nil)
          (l2s-test-warnings nil))
     (unwind-protect
         (with-temp-buffer
          (cl-letf
             (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (unless (buffer-live-p (plist-get plist :buffer))
                   (error "Process output buffer is not live"))
                 ;; As `make-process' does for a program not on `exec-path'.
                 (let ((program (car (plist-get plist :command))))
                   (when (member program l2s-test-missing)
                     (signal 'file-missing
                             (list "Searching for program"
                                   "No such file or directory" program))))
                 (let ((process
                        (vector 'fake-process 'run 0 plist default-directory
                                process-environment)))
                   (push process l2s-test-processes)
                   process)))
              ((symbol-function 'process-status)
               (lambda (process) (aref process 1)))
              ((symbol-function 'process-exit-status)
               (lambda (process) (aref process 2)))
              ((symbol-function 'delete-process)
               ;; As Emacs does, the sentinel runs before `delete-process'
               ;; returns.
               (lambda (process)
                 (latex-to-svg-backend-tests--finish-fake-process
                  process 9 nil 'signal)))
              ((symbol-function 'display-warning)
               (lambda (&rest warning)
                 (push warning l2s-test-warnings)))
              ((symbol-function 'start-process-shell-command)
               (lambda (&rest _)
                 (error "A shell pipeline must not be used"))))
           ,@body))
       ;; The scratch directories are in the cache directory.
       (dolist (process l2s-test-processes)
         (let ((buffer (plist-get (aref process 3) :buffer)))
           (when (buffer-live-p buffer)
             (kill-buffer buffer))))
       (when (file-directory-p l2s-test-cache-dir)
         (delete-directory l2s-test-cache-dir t)))))

(ert-deftest latex-to-svg-backend-compile-direct-argv-ignores-user-shell ()
  ;; A Nu or invalid user shell is irrelevant: latex is started directly,
  ;; followed by dvisvgm only after the expected DVI appears.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((shell-file-name "nu")
           (latex-to-svg-backend-metadata-prefix "L2S")
           (doc "$x^2$")
           (key (latex-to-svg-backend--cache-key doc))
           (callbacks 0)
           metadata-seen)
      (puthash
       key
       (list (latex-to-svg-backend--waiter
              (lambda (_outcome) (error "callback marker")))
             (latex-to-svg-backend--waiter
              (lambda (_outcome)
                (cl-incf callbacks)
                (setq metadata-seen (latex-to-svg-backend-metadata doc)))))
       latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc 3)
      (should (= (length l2s-test-processes) 1))
      (let* ((latex-process (car l2s-test-processes))
             (latex-plist (aref latex-process 3))
             (latex-command (plist-get latex-plist :command))
             (scratch (aref latex-process 4))
             (output-buffer (plist-get latex-plist :buffer))
             (dvi (expand-file-name "equation.dvi" scratch))
             (tex-log (expand-file-name "equation.log" scratch))
             (svg (expand-file-name "equation.svg" scratch)))
        (should (equal latex-command
                       (list "latex-direct"
                             "-interaction=nonstopmode"
                             "-halt-on-error"
                             "equation.tex")))
        (should (equal (plist-get latex-plist :connection-type) 'pipe))
        (should (plist-get latex-plist :noquery))
        (should (equal scratch (file-name-as-directory scratch)))
        (with-temp-file dvi
          (insert "fake dvi"))
        (with-temp-file tex-log
          (insert "L2S 3\n"))
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 2))
        (let* ((dvisvgm-process (car l2s-test-processes))
               (dvisvgm-plist (aref dvisvgm-process 3)))
          (should (equal (aref dvisvgm-process 4) scratch))
          (should
           (equal (plist-get dvisvgm-plist :command)
                  (list "dvisvgm-direct"
                        "--no-fonts" "--exact-bbox" "--currentcolor"
                        "--scale=1" "-o" svg dvi)))
          (with-temp-file svg
            (insert "<svg/>"))
          (latex-to-svg-backend-tests--finish-fake-process
           dvisvgm-process 0))
        (should-not (file-exists-p svg))
        (should (file-exists-p (latex-to-svg-backend--svg-file key)))
        (should (= callbacks 1))
        (should (equal metadata-seen '(:nums (3 . 3))))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should-not (buffer-live-p output-buffer))))))

(ert-deftest latex-to-svg-backend-latex-failure-saves-process-output ()
  ;; If latex fails before producing equation.log, captured stderr and the
  ;; terminal status are persisted; dvisvgm is not started.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$bad$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list (latex-to-svg-backend--waiter #'ignore))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (output-buffer (plist-get (aref latex-process 3) :buffer))
             (scratch (aref latex-process 4))
             (log (expand-file-name (concat key ".log")
                                    (latex-to-svg-backend--shard-dir key))))
        (latex-to-svg-backend-tests--finish-fake-process
         latex-process 1 "latex stderr marker\n")
        (should (= (length l2s-test-processes) 1))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should-not (buffer-live-p output-buffer))
        (should (file-exists-p log))
        (with-temp-buffer
          (insert-file-contents log)
          (should (search-forward "latex stderr marker" nil t))
          (should (search-forward
                   "[latex] status=exit exit-status=1" nil t))
          (should (search-forward
                   "event=\"exited abnormally with code 1\\n\"" nil t)))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-missing-stage-output-is-logged ()
  ;; A zero exit without the promised DVI fails with an explicit diagnostic.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$no-dvi$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list (latex-to-svg-backend--waiter #'ignore))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (scratch (aref latex-process 4))
             (dvi (expand-file-name "equation.dvi" scratch))
             (log (expand-file-name (concat key ".log")
                                    (latex-to-svg-backend--shard-dir key))))
        (should-not (file-exists-p dvi))
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 1))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (with-temp-buffer
          (insert-file-contents log)
          (should (search-forward
                   "[latex] status=exit exit-status=0" nil t))
          (should (search-forward "[latex] expected output missing:" nil t))
          (should (search-forward "equation.dvi" nil t)))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-dead-process-log-still-cleans-up ()
  ;; Logging is best-effort: a dead output buffer that makes the next stage
  ;; fail to start must not suppress completion or leak pending/scratch state.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$x$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list (latex-to-svg-backend--waiter #'ignore))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (output-buffer (plist-get (aref latex-process 3) :buffer))
             (scratch (aref latex-process 4))
             (dvi (expand-file-name "equation.dvi" scratch)))
        (with-temp-file dvi
          (insert "fake dvi"))
        (kill-buffer output-buffer)
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 1))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-dvisvgm-signal-keeps-both-logs ()
  ;; A second-stage signal keeps equation.log, process output, and signal data.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$bad-svg$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list (latex-to-svg-backend--waiter #'ignore))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (scratch (aref latex-process 4))
             (dvi (expand-file-name "equation.dvi" scratch))
             (tex-log (expand-file-name "equation.log" scratch))
             (log (expand-file-name (concat key ".log")
                                    (latex-to-svg-backend--shard-dir key))))
        (with-temp-file dvi
          (insert "fake dvi"))
        (with-temp-file tex-log
          (insert "equation.log marker\n"))
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 2))
        (latex-to-svg-backend-tests--finish-fake-process
         (car l2s-test-processes) 9 "dvisvgm stderr marker\n"
         'signal "killed by signal 9\n")
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (with-temp-buffer
          (insert-file-contents log)
          (should (search-forward "equation.log marker" nil t))
          (should (search-forward "dvisvgm stderr marker" nil t))
          (should (search-forward
                   "[dvisvgm] status=signal exit-status=9" nil t))
          (should (search-forward
                   "event=\"killed by signal 9\\n\"" nil t)))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-runs-at-most-jobs-compiles ()
  ;; With two slots a third equation waits, and a second request for it
  ;; joins the queued compile.  When a compile ends, failed here, the
  ;; queued one starts.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((latex-to-svg-backend-jobs 2)
           (latex-to-svg-backend-ratex-program "ratex-direct")
           (latex-to-svg-backend-ratex-macros "")
           (docs '("$a$" "$b$" "$c$"))
           (keys (mapcar (lambda (doc)
                           (latex-to-svg-backend--cache-key doc 'ratex))
                         docs)))
      (dolist (doc (append docs '("$c$")))
        (latex-to-svg-backend--enqueue
         (latex-to-svg-backend--cache-key doc 'ratex) doc
         (latex-to-svg-backend--waiter #'ignore t) nil 'ratex))
      (should (= (length l2s-test-processes) 2))
      (should (equal (mapcar #'car latex-to-svg-backend--queue)
                     (list (nth 2 keys))))
      (should (= 2 (length (gethash (nth 2 keys)
                                    latex-to-svg-backend--pending))))
      ;; `render-svg' for $a$ exits without an SVG.
      (latex-to-svg-backend-tests--finish-fake-process
       (car (last l2s-test-processes)) 0)
      (should (= (length l2s-test-processes) 3))
      (should-not latex-to-svg-backend--queue)
      (should (equal (sort (copy-sequence latex-to-svg-backend--running)
                           #'string<)
                     (sort (list (nth 1 keys) (nth 2 keys)) #'string<))))))

(ert-deftest latex-to-svg-backend-compile-that-cannot-start-frees-its-slot ()
  ;; A compile that signals as it starts is reported in the buffer waiting
  ;; for it and ended, so
  ;; its slot goes to the next one and a later request compiles again.
  (let ((latex-to-svg-backend-jobs 1)
        (latex-to-svg-backend--pending (make-hash-table :test 'equal))
        (latex-to-svg-backend--queue nil)
        (latex-to-svg-backend--running nil)
        (warnings nil)
        (started nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest warning) (push warning warnings))))
      (puthash "a" (list (latex-to-svg-backend--waiter #'ignore))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--schedule
       "a" (lambda () (error "No scratch directory")))
      (latex-to-svg-backend--schedule "b" (lambda () (push "b" started)))
      (should (equal started '("b")))
      (should (equal latex-to-svg-backend--running '("b")))
      (should-not (gethash "a" latex-to-svg-backend--pending))
      (should (= (length warnings) 1)))))

(ert-deftest latex-to-svg-backend-jobs-defaults-to-the-processors ()
  (let ((latex-to-svg-backend-jobs nil))
    (should (= (latex-to-svg-backend--jobs) (num-processors))))
  (let ((latex-to-svg-backend-jobs 0))
    (should (= (latex-to-svg-backend--jobs) 1))))

;;;; End-to-end (requires latex + dvisvgm; skipped otherwise)

(ert-deftest latex-to-svg-backend-compiles-verbatim-display-math ()
  ;; Guards the `varwidth' invariant: the verbatim body must accept *display*
  ;; math (`\[...\]', `equation', `align'), not just inline `$...$'.  Plain
  ;; `standalone' errors with "Missing $ inserted" on display math, so a
  ;; regression in `latex-to-svg-backend-preamble-base' would fail these
  ;; real compiles.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-e2e" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (dolist (doc '("$E=mc^2$"
                         "\\[F=ma\\]"
                         "\\begin{equation}\nx=1\n\\end{equation}"
                         "\\begin{align}\na&=b\\\\\nc&=d\n\\end{align}"))
            (let ((done 'pending))
              (latex-to-svg-backend doc :callback (lambda (outcome) (setq done (or outcome t))))
              (dotimes (_ 100)
                (when (eq done 'pending)
                  (accept-process-output nil 0.1)))
              (should (eq done t))
              (should (file-exists-p
                       (latex-to-svg-backend--svg-file (latex-to-svg-backend--cache-key doc)))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Invalidate

(ert-deftest latex-to-svg-backend-invalidate-drops-disk-and-memory ()
  ;; `latex-to-svg-backend-invalidate' removes LATEX's on-disk SVG and every in-memory
  ;; image built from it (any scale/color), leaving other entries intact.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-inv" t))
        (latex-to-svg-backend--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (file (latex-to-svg-backend--svg-file key)))
          (with-temp-file file (insert "<svg/>"))
          (puthash (concat key "@1.0@#000000") 'img-a latex-to-svg-backend--image-cache)
          (puthash (concat key "@2.0@#ffffff") 'img-b latex-to-svg-backend--image-cache)
          (puthash "otherkey@1.0@#000000" 'other latex-to-svg-backend--image-cache)
          (should (file-exists-p file))
          (latex-to-svg-backend-invalidate "$x$")
          ;; On-disk SVG gone.
          (should-not (file-exists-p file))
          ;; Both images for this key dropped; the unrelated entry survives.
          (should (= 1 (hash-table-count latex-to-svg-backend--image-cache)))
          (should (eq 'other (gethash "otherkey@1.0@#000000"
                                      latex-to-svg-backend--image-cache))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-tolerates-missing ()
  ;; Invalidating something never rendered is a no-op, not an error.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-inv2" t)))
    (unwind-protect
        (should-not (latex-to-svg-backend-invalidate "$never-rendered$"))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Compile metadata (.eld sidecar)

(defun latex-to-svg-backend-tests--write-log (key body)
  "Write a fake compile scratch dir containing BODY as `equation.log'.
Return the scratch directory (caller deletes it).  KEY is unused here but
kept for symmetry with the compile pipeline."
  (ignore key)
  (let ((dir (make-temp-file "l2s-log" t)))
    (with-temp-file (expand-file-name "equation.log" dir) (insert body))
    dir))

(ert-deftest latex-to-svg-backend-failure-log-copies-raw-bytes ()
  ;; A TeX log echoing bytes that no default coding system can encode (an
  ;; unrecognized Unicode char in the equation) must be copied verbatim, not
  ;; make `write-region' prompt for a coding system from a background compile.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-rawlog" t))
         (key (latex-to-svg-backend--cache-key "$\xce\xb1$"))
         (raw (concat "! Package inputenc Error: Unicode character "
                      (unibyte-string #xce #xb8) " not set up.\n"))
         (dir (make-temp-file "l2s-rawlog-src" t))
         (dst (expand-file-name (concat key ".log")
                                (latex-to-svg-backend--shard-dir key))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region raw nil (expand-file-name "equation.log" dir)))
          ;; `select-safe-coding-system' must never be reached.
          (cl-letf (((symbol-function 'select-safe-coding-system)
                     (lambda (&rest _) (error "prompted for a coding system")))
                    ((symbol-function 'display-warning) #'ignore))
            (latex-to-svg-backend--compile-failed key "$x$" dir "stderr tail\n"))
          (should (file-exists-p dst))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (let ((coding-system-for-read 'binary))
              (insert-file-contents-literally dst))
            (goto-char (point-min))
            (should (search-forward (unibyte-string #xce #xb8) nil t))
            (should (search-forward "stderr tail" nil t))))
      (delete-directory dir t)
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-round-trips ()
  ;; With a prefix set, `--write-metadata' captures FINAL (first integer on a
  ;; matching log line) and pairs it with the caller-supplied INITIAL, storing
  ;; `(INITIAL . FINAL)'; `latex-to-svg-backend-metadata' reads it back on a cache hit.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta" t))
        (latex-to-svg-backend-metadata-prefix "L2S"))
    (unwind-protect
        (let* ((latex "\\setcounter{equation}{2}\\begin{equation}x\\end{equation}")
               (key (latex-to-svg-backend--cache-key latex))
               (dir (latex-to-svg-backend-tests--write-log
                     key (concat "This is pdfTeX...\n"
                                 "Overfull \\hbox ...\n"
                                 "L2S 3\n"))))
          (unwind-protect
              (progn
                ;; INITIAL = K+1 = 3, supplied by the caller; FINAL = 3 from log.
                (latex-to-svg-backend--write-metadata key dir 3)
                (should (file-exists-p (latex-to-svg-backend--meta-file key)))
                (should (equal (latex-to-svg-backend-metadata latex)
                               '(:nums (3 . 3)))))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-disabled-writes-nothing ()
  ;; With no prefix the backend captures nothing and writes no sidecar.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-off" t))
        (latex-to-svg-backend-metadata-prefix nil))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (dir (latex-to-svg-backend-tests--write-log key "L2S 3\n")))
          (unwind-protect
              (progn
                (latex-to-svg-backend--write-metadata key dir 3)
                (should-not (file-exists-p (latex-to-svg-backend--meta-file key)))
                (should-not (latex-to-svg-backend-metadata "$x$")))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-needs-a-final ()
  ;; No FINAL captured from the log => no sidecar (nothing to reconcile).
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-none" t))
        (latex-to-svg-backend-metadata-prefix "L2S"))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (dir (latex-to-svg-backend-tests--write-log key "just noise\n")))
          (unwind-protect
              (progn
                (latex-to-svg-backend--write-metadata key dir 3)
                (should-not (file-exists-p (latex-to-svg-backend--meta-file key))))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-missing-and-corrupt-yield-nil ()
  ;; No sidecar => nil, and nothing to report (an equation compiled before the
  ;; prefix was set simply has none).  A half-written / corrupt sidecar => nil
  ;; too, with no warning: it is cache, and the entry is rebuilt.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-bad" t))
        (warnings 0))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (cl-incf warnings))))
          (setq latex-to-svg-backend--warned nil)
          (should-not (latex-to-svg-backend-metadata "$never$"))
          (should (= 0 warnings))
          (with-temp-file (latex-to-svg-backend--meta-file (latex-to-svg-backend--cache-key "$x$"))
            (insert "(:nums (3 . "))    ; truncated, unreadable
          (should-not (latex-to-svg-backend-metadata "$x$"))
          (should-not (latex-to-svg-backend-metadata "$x$"))
          (should (= 0 warnings)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-unreadable-sidecar-regenerates-the-entry ()
  ;; Only a compile can rewrite a metadata sidecar, and a cached SVG means no
  ;; compile ever happens -- so an unreadable sidecar would cost the equation
  ;; its metadata permanently.  Discard the entry instead: the next render
  ;; rebuilds both.  That is a cache rebuilding itself, so nothing is reported.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-fix" t))
        (warnings 0))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (cl-incf warnings))))
          (setq latex-to-svg-backend--warned nil)
          (clrhash latex-to-svg-backend--metadata-repaired)
          (clrhash latex-to-svg-backend--image-cache)
          (let* ((latex "$x$")
                 (key (latex-to-svg-backend--cache-key latex))
                 (svg (latex-to-svg-backend--svg-file key))
                 (meta (latex-to-svg-backend--meta-file key)))
            ;; A cached SVG, a warm image, and a sidecar truncated mid-write.
            (with-temp-file svg (insert "<svg/>"))
            (with-temp-file meta (insert "(:nums (3 . "))
            (puthash (concat key "@0.8@#000000@nil@nil") 'IMG
                     latex-to-svg-backend--image-cache)
            (should-not (latex-to-svg-backend-metadata latex))
            (should (= 0 warnings))
            ;; Entry gone: SVG, sidecar, and the warm image.
            (should-not (file-exists-p meta))
            (should-not (file-exists-p svg))
            (should (= 0 (hash-table-count latex-to-svg-backend--image-cache)))
            ;; At most one repair per equation: if a freshly written sidecar
            ;; came back unreadable too, this must not recompile on every
            ;; query.
            (with-temp-file svg (insert "<svg/>"))
            (with-temp-file meta (insert "(:nums (3 . "))
            (should-not (latex-to-svg-backend-metadata latex))
            (should (file-exists-p svg))
            (should (= 0 warnings))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-write-metadata-failure-lets-the-equation-through ()
  ;; --write-metadata runs in the compile sentinel, before the pending
  ;; callbacks fire: a sidecar it cannot write must be reported, not signalled,
  ;; or a successfully compiled equation would never be placed.  It is
  ;; reported in the buffer that requested the compile, once.
  (let ((latex-to-svg-backend-metadata-prefix "L2S")
        (latex-to-svg-backend--pending (make-hash-table :test 'equal))
        (dir (make-temp-file "l2s-meta-w" t))
        (warnings nil))
    (unwind-protect
        (with-temp-buffer
          (puthash "K" (list (latex-to-svg-backend--waiter #'ignore))
                   latex-to-svg-backend--pending)
          (with-temp-file (expand-file-name "equation.log" dir) (insert "L2S 42\n"))
          (cl-letf (((symbol-function 'latex-to-svg-backend--meta-file)
                     (lambda (&rest _) "/l2s-no-such-dir-9182/x.eld"))
                    ((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (let ((requester (current-buffer)))
              (with-temp-buffer
                (latex-to-svg-backend--write-metadata "K" dir 3)
                (latex-to-svg-backend--write-metadata "K" dir 3))
              (should (= 1 (length warnings)))
              (should (string-prefix-p (buffer-name requester) (car warnings))))))
      (delete-directory dir t))))

(ert-deftest latex-to-svg-backend-unusable-gc-stamp-self-heals ()
  ;; The GC cadence stamp: an unusable one means "never collected", so the next
  ;; GC runs and rewrites it.  That is a cache rebuilding itself: no warning.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-stamp" t))
        (warnings 0))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (cl-incf warnings))))
          ;; Never collected: not an error.
          (should (= 0 (latex-to-svg-backend--last-gc-time)))
          ;; Truncated by a crash mid-write.
          (with-temp-file (latex-to-svg-backend--gc-stamp-file) (insert "(12345"))
          (should (= 0 (latex-to-svg-backend--last-gc-time)))
          ;; Parses, but is not a time.
          (with-temp-file (latex-to-svg-backend--gc-stamp-file) (insert "yesterday"))
          (should (= 0 (latex-to-svg-backend--last-gc-time)))
          ;; Self-healing: a GC rewrites a usable stamp.
          (latex-to-svg-backend--record-gc-time)
          (should (> (latex-to-svg-backend--last-gc-time) 0))
          (should (= 0 warnings)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-unwritable-gc-stamp-warns-each-time ()
  ;; No buffer requests the GC, so there is none to mark: a stamp that cannot
  ;; be written warns at every collection.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-stamp" t))
        (warnings nil))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend--gc-stamp-file)
                   (lambda () "/l2s-no-such-dir-9182/gc-timestamp"))
                  ((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (latex-to-svg-backend--record-gc-time)
          (latex-to-svg-backend--record-gc-time)
          (should (= 2 (length warnings)))
          (should (string-search "latex-to-svg-backend-cache-directory"
                                 (car warnings))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-captured-from-real-compile ()
  ;; End to end (needs latex + dvisvgm): a `\typeout{L2S-AFTER=...}' injected
  ;; into the body is captured from the real compile log into `<key>.eld' and
  ;; read back — exercising actual TeX log formatting, not a synthetic log.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-e2e" t))
        (latex-to-svg-backend-metadata-prefix "L2S"))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (let* ((doc (concat "\\setcounter{equation}{6}%\n"
                              "\\begin{equation}x=1\\end{equation}\n"
                              "\\typeout{L2S \\arabic{equation}}%\n"))
                 (done 'pending))
            ;; INITIAL = K+1 = 7 supplied in Elisp; FINAL = 7 from the compile.
            (latex-to-svg-backend doc :callback (lambda (outcome) (setq done (or outcome t))) :metadata 7)
            (dotimes (_ 100)
              (when (eq done 'pending) (accept-process-output nil 0.1)))
            (should (eq done t))
            (should (equal (latex-to-svg-backend-metadata doc)
                           '(:nums (7 . 7))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-drops-metadata-sidecar ()
  ;; Invalidate removes the `.eld' alongside the `.svg' so they stay coupled.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-inv" t)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (svg (latex-to-svg-backend--svg-file key))
               (meta (latex-to-svg-backend--meta-file key)))
          (with-temp-file svg (insert "<svg/>"))
          (with-temp-file meta (prin1 '(:nums (1 . 1))
                                      (current-buffer)))
          (latex-to-svg-backend-invalidate "$x$")
          (should-not (file-exists-p svg))
          (should-not (file-exists-p meta)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Preamble precompilation (.fmt)

(ert-deftest latex-to-svg-backend-format-key-folds-in-preamble ()
  ;; The key names the `.fmt' file; it must change when the preamble (base
  ;; or appended) or the LaTeX program changes, so a stale `.fmt' file is never
  ;; reused after a preamble edit.
  (let ((base (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble))))
    (should (equal base (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble))))
    (let ((latex-to-svg-backend-preamble-packages "\\usepackage{physics}"))
      (should-not (equal base (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble)))))
    (let ((latex-to-svg-backend-preamble-base "\\documentclass{minimal}"))
      (should-not (equal base (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble)))))
    (let ((latex-to-svg-backend-latex-program "xelatex"))
      (should-not (equal base (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble)))))))

(ert-deftest latex-to-svg-backend-preamble-appends ()
  ;; The combined preamble is the base alone when nothing is appended, else
  ;; base + newline + appended (the exact text dumped and embedded).
  (let ((latex-to-svg-backend-preamble-base "BASE")
        (latex-to-svg-backend-preamble-packages ""))
    (should (equal (latex-to-svg-backend--preamble) "BASE")))
  (let ((latex-to-svg-backend-preamble-base "BASE")
        (latex-to-svg-backend-preamble-packages "EXTRA"))
    (should (equal (latex-to-svg-backend--preamble) "BASE\nEXTRA"))))

(ert-deftest latex-to-svg-backend-preamble-appends-line-width ()
  ;; A non-nil `latex-to-svg-backend-line-width' appends a `\sa@width'
  ;; override (last, so it wins over the class default); nil appends nothing.
  (let ((latex-to-svg-backend-preamble-base "BASE")
        (latex-to-svg-backend-preamble-packages "")
        (latex-to-svg-backend-line-width nil))
    (should (equal (latex-to-svg-backend--preamble) "BASE")))
  (let ((latex-to-svg-backend-preamble-base "BASE")
        (latex-to-svg-backend-preamble-packages "EXTRA")
        (latex-to-svg-backend-line-width "18cm"))
    (should (equal (latex-to-svg-backend--preamble)
                   "BASE\nEXTRA\n\\makeatletter\\def\\sa@width{18cm}\\makeatother"))))

(ert-deftest latex-to-svg-backend-ensure-format-nil-when-disabled ()
  ;; With precompilation off, no `.fmt' file is dumped or consulted.
  (let ((latex-to-svg-backend-precompile nil))
    (cl-letf (((symbol-function 'latex-to-svg-backend--build-format)
               (lambda (_k _preamble &optional _program _package-files) (error "must not dump when disabled"))))
      (should-not (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))))))

(ert-deftest latex-to-svg-backend-ensure-format-builds-once-and-reuses ()
  ;; First call builds the `.fmt' (stubbed); the session then reuses it
  ;; with no rebuild.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
        ;; A binary older than the about-to-be-built .fmt.
        (binary (make-temp-file "l2s-bin"))
        (builds 0))
    (set-file-times binary '(1 0))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                   (lambda (&optional _program) binary))
                  ((symbol-function 'latex-to-svg-backend--build-format)
                   (lambda (fkey _preamble &optional _program _package-files)
                     (cl-incf builds)
                     (let ((f (latex-to-svg-backend--format-file fkey)))
                       (with-temp-file f (insert "fmt"))
                       (latex-to-svg-backend--write-format-stamp f binary)
                       f))))
          (let ((f1 (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))))
            (should f1)
            (should (file-exists-p f1))
            (should (= builds 1))
            ;; Second call: verified fresh, served from disk, no rebuild.
            (should (equal f1 (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))))
            (should (= builds 1))))
      (delete-file binary)
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-ensure-format-rebuilds-when-stale ()
  ;; A `.fmt' with no stamp (dumped before stamps existed) is deleted and
  ;; rebuilt rather than reused.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-stale" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
        (builds 0))
    (unwind-protect
        (let* ((fkey (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble)))
               (fmt (latex-to-svg-backend--format-file fkey))
               (newer-bin (make-temp-file "l2s-bin")))
          ;; An old .fmt on disk with no stamp.
          (with-temp-file fmt (insert "old"))
          (set-file-times fmt '(1 0))
          (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                     (lambda (&optional _program) newer-bin))
                    ((symbol-function 'latex-to-svg-backend--build-format)
                     (lambda (k _preamble &optional _program _package-files)
                       (cl-incf builds)
                       (let ((f (latex-to-svg-backend--format-file k)))
                         (with-temp-file f (insert "new")) f))))
            (should (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble)))
            (should (= builds 1))
            (should (equal (with-temp-buffer (insert-file-contents fmt)
                                             (buffer-string))
                           "new"))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-flush-format-clears-everything ()
  ;; `latex-to-svg-backend-flush-format' deletes every `.fmt' and resets session state.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-flush" t))
        (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal)))
    (unwind-protect
        (let ((fmt-dir (latex-to-svg-backend--fmt-dir))
              (svg (latex-to-svg-backend--svg-file
                    (latex-to-svg-backend--cache-key "$keep$"))))
          (with-temp-file (expand-file-name "aaa.fmt" fmt-dir) (insert "1"))
          (with-temp-file (expand-file-name "bbb.fmt" fmt-dir) (insert "2"))
          ;; A cached SVG (in the `svg/' subtree) must survive the flush.
          (with-temp-file svg (insert "<svg/>"))
          (puthash "aaa" t latex-to-svg-backend--format-stamps)
          (latex-to-svg-backend-flush-format)
          (should-not (directory-files fmt-dir nil "\\.fmt\\'"))
          (should (file-exists-p svg))
          (should (= 0 (hash-table-count latex-to-svg-backend--format-stamps))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-precompiled-compile-end-to-end ()
  ;; End to end (needs latex + dvisvgm): a real compile through the
  ;; precompiled preamble produces the SVG, and the `.fmt' is left cached.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-e2e" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (let ((done 'pending)
                (doc "\\begin{equation}\ne^{i\\pi}+1=0\n\\end{equation}"))
            (latex-to-svg-backend doc :callback (lambda (outcome) (setq done (or outcome t))))
            (dotimes (_ 200)
              (when (eq done 'pending) (accept-process-output nil 0.1)))
            (should (eq done t))
            (should (file-exists-p
                     (latex-to-svg-backend--svg-file (latex-to-svg-backend--cache-key doc))))
            ;; The `.fmt' file was dumped and cached alongside the SVG.
            (should (file-exists-p
                     (latex-to-svg-backend--format-file (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble)))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Cache sharding

(ert-deftest latex-to-svg-backend-svg-file-is-sharded-by-key-prefix ()
  ;; The SVG (and its `.eld' sidecar) live in a subdirectory named by the
  ;; first two characters of the content key, created on demand.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-shard" t)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (svg (latex-to-svg-backend--svg-file key))
               (eld (latex-to-svg-backend--meta-file key))
               (bucket (substring key 0 2)))
          (should (equal (file-name-nondirectory
                          (directory-file-name (file-name-directory svg)))
                         bucket))
          ;; SVG and sidecar share the same bucket, which now exists.
          (should (equal (file-name-directory svg) (file-name-directory eld)))
          (should (file-directory-p (file-name-directory svg)))
          (should (equal (file-name-nondirectory svg) (concat key ".svg"))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-works-with-sharding ()
  ;; `invalidate' removes the sharded SVG and its sidecar.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-shard-inv" t))
        (latex-to-svg-backend--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$y$"))
               (svg (latex-to-svg-backend--svg-file key))
               (eld (latex-to-svg-backend--meta-file key)))
          (with-temp-file svg (insert "<svg/>"))
          (with-temp-file eld (prin1 '(:nums (1 . 1)) (current-buffer)))
          (latex-to-svg-backend-invalidate "$y$")
          (should-not (file-exists-p svg))
          (should-not (file-exists-p eld)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Cache garbage collection

(defun latex-to-svg-backend-tests--fake-entry (latex bytes age-days)
  "Write a fake cache SVG of BYTES for LATEX, dated AGE-DAYS in the past.
Return the SVG path."
  (let ((svg (latex-to-svg-backend--svg-file (latex-to-svg-backend--cache-key latex)))
        (ts (- (float-time) (* age-days 86400))))
    (with-temp-file svg (insert (make-string bytes ?x)))
    (set-file-times svg (seconds-to-time ts))
    svg))

(ert-deftest latex-to-svg-backend-gc-expires-by-age ()
  ;; Entries older than the age cap are deleted (with siblings); fresh ones stay.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-age" t))
        (latex-to-svg-backend-cache-max-age 30))
    (unwind-protect
        (let ((old (latex-to-svg-backend-tests--fake-entry "$old$" 10 90))
              (new (latex-to-svg-backend-tests--fake-entry "$new$" 10 1))
              ;; A sidecar next to the stale SVG must go with it.
              (old-eld (latex-to-svg-backend--meta-file
                        (latex-to-svg-backend--cache-key "$old$"))))
          (with-temp-file old-eld (prin1 '(:nums (1 . 1)) (current-buffer)))
          (let ((res (latex-to-svg-backend-gc)))
            (should (= 1 (car res))))
          (should-not (file-exists-p old))
          (should-not (file-exists-p old-eld))
          (should (file-exists-p new)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-gc-records-timestamp-and-gates-cadence ()
  ;; `--maybe-gc' runs when the interval has elapsed and no-ops when it hasn't.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-stamp" t))
        (latex-to-svg-backend-cache-max-age nil)
        (latex-to-svg-backend-gc-interval 1))
    (unwind-protect
        (progn
          (should (= 0 (latex-to-svg-backend--last-gc-time)))
          ;; First check runs a GC and records the time.
          (let ((ran nil))
            (cl-letf (((symbol-function 'latex-to-svg-backend-gc)
                       (lambda () (setq ran t)
                         (latex-to-svg-backend--record-gc-time) '(0 . 0))))
              (latex-to-svg-backend--maybe-gc)
              (should ran)
              (should (> (latex-to-svg-backend--last-gc-time) 0))
              ;; Second check within the interval is a no-op.
              (setq ran nil)
              (latex-to-svg-backend--maybe-gc)
              (should-not ran)))
          ;; A nil interval disables automatic GC entirely.
          (let ((latex-to-svg-backend-gc-interval nil) (ran nil))
            (cl-letf (((symbol-function 'latex-to-svg-backend-gc)
                       (lambda () (setq ran t) '(0 . 0))))
              (latex-to-svg-backend--maybe-gc)
              (should-not ran))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-clear-cache-empties-svgs-keeps-fmt ()
  ;; `clear-cache' deletes svg/eld across shards and empties the image cache,
  ;; but leaves `.fmt' files alone.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-clear" t))
        (latex-to-svg-backend--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let ((svg (latex-to-svg-backend-tests--fake-entry "$z$" 10 1))
              (eld (latex-to-svg-backend--meta-file
                    (latex-to-svg-backend--cache-key "$z$")))
              (fmt (latex-to-svg-backend--format-file "deadbeef")))
          (with-temp-file eld (prin1 '(:nums (1 . 1)) (current-buffer)))
          (with-temp-file fmt (insert "format"))
          (puthash "k@1.0@#000000" 'img latex-to-svg-backend--image-cache)
          (latex-to-svg-backend-clear-cache)
          (should-not (file-exists-p svg))
          (should-not (file-exists-p eld))
          (should (file-exists-p fmt))
          (should (= 0 (hash-table-count latex-to-svg-backend--image-cache))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-writes-the-tex-as-utf-8 ()
  ;; The equation source is written as UTF-8, pinned, whatever the user's
  ;; default coding system is.  Unpinned, a character that default cannot
  ;; encode (an alpha under a Latin-1 language environment) sends
  ;; `write-region' through `select-safe-coding-system-function', which
  ;; *prompts* -- fatal in a background compile, and no `.tex' is written at
  ;; all.  Pinning means that function is never consulted, which is the
  ;; invariant asserted here (a prompt cannot be asserted on directly
  ;; without a language-environment switch, and a regression must fail the
  ;; suite rather than hang it).  This is also why the preamble needs no
  ;; `inputenc' line: LaTeX reads UTF-8 by default and the backend writes it.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((coding-system-for-write nil)
           (select-safe-coding-system-function
            (lambda (&rest _)
              (error "coding system not pinned: the write would have prompted")))
           (doc "$\\alpha = \u03b1$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list (latex-to-svg-backend--waiter #'ignore))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((tex (latex-to-svg-backend-tests--tex-file (car l2s-test-processes)))
             (bytes (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally tex)
                      (buffer-string))))
        ;; U+03B1 as UTF-8 is CE B1, not a locale-dependent single byte.
        (should (string-match-p "\316\261" bytes))
        (should (equal (latex-to-svg-backend-tests--tex-source tex)
                       (concat (latex-to-svg-backend--preamble) "\n"
                               "\\begin{document}\n" doc "\n"
                               latex-to-svg-backend--latex-baseline-mark
                               latex-to-svg-backend--latex-x-height-mark
                               "\\end{document}\n")))))))

(ert-deftest latex-to-svg-backend-safe-locals-exclude-the-dangerous-ones ()
  ;; A `:safe' defcustom is applied from a file's `-*-' line or a
  ;; `.dir-locals.el' with no prompt, so opening someone else's file applies
  ;; it.  These decide what is executed, what LaTeX code is compiled, and
  ;; which directory the collector deletes files in -- they must never be
  ;; marked safe, whatever else is.
  (dolist (v '(latex-to-svg-backend-latex-program
               latex-to-svg-backend-dvisvgm-program
               latex-to-svg-backend-preamble-base
               latex-to-svg-backend-preamble-packages
               latex-to-svg-backend-preamble-not-precompiled
               latex-to-svg-backend-cache-directory
               latex-to-svg-backend-ratex-program
               latex-to-svg-backend-ratex-macros
               latex-to-svg-backend-texres-program
               latex-to-svg-backend-pdftocairo-program))
    (should (get v 'custom-type))
    (should-not (get v 'safe-local-variable))))

(ert-deftest latex-to-svg-backend-preamble-file-lists-are-safe ()
  ;; The two file lists are inert: only their files' modification times
  ;; are read.  The predicate admits a list of strings only.
  (dolist (v '(latex-to-svg-backend-preamble-package-files
               latex-to-svg-backend-preamble-not-precompiled-files))
    (let ((safe (get v 'safe-local-variable)))
      (should safe)
      (should (funcall safe nil))
      (should (funcall safe '("macros.tex" "/abs/x.sty")))
      (should-not (funcall safe "macros.tex"))
      (should-not (funcall safe '(macros))))))

(ert-deftest latex-to-svg-backend-line-width-safe-rejects-latex-code ()
  ;; `-line-width' IS safe, but only because its predicate admits nothing but
  ;; a bare dimension: the value is interpolated verbatim into
  ;; `\def\sa@width{...}', so a brace or backslash would be LaTeX injection.
  (let ((safe (get 'latex-to-svg-backend-line-width 'safe-local-variable)))
    (should safe)
    (dolist (ok '(nil "345pt" "12.5cm" "-3in" ".5em" "1sp"))
      (should (funcall safe ok)))
    (dolist (bad (list "1pt}\\input{/etc/passwd}\\def\\x{" "\\linewidth"
                       "345 pt" "345" "pt" "345px" 345))
      (should-not (funcall safe bad)))))

;;;; Engine choice

(ert-deftest latex-to-svg-backend-latex-cache-key-is-unchanged ()
  ;; Adding an engine must not re-key the LaTeX engine's cache: every
  ;; user's warm cache would be recompiled.  This is the formula the key had
  ;; before the engine choice existed, with the engine left out (as
  ;; every existing caller does) and named.
  (let ((key (secure-hash 'sha1
                          (format "%d\0%s\0%s"
                                  latex-to-svg-backend--cache-version
                                  "E=mc^2"
                                  (latex-to-svg-backend--preamble)))))
    (should (equal (latex-to-svg-backend--cache-key "E=mc^2") key))
    (should (equal (latex-to-svg-backend--cache-key "E=mc^2" 'latex) key))))

(ert-deftest latex-to-svg-backend-cache-key-separates-engines ()
  ;; The same LaTeX gets one key per engine, the RaTeX key follows the
  ;; macros and not the LaTeX preamble.
  (let* ((latex-to-svg-backend-ratex-macros "")
         (latex-key (latex-to-svg-backend--cache-key "$x$" 'latex))
         (ratex-key (latex-to-svg-backend--cache-key "$x$" 'ratex)))
    (should-not (equal latex-key ratex-key))
    (let ((latex-to-svg-backend-preamble-base "\\documentclass{minimal}"))
      (should (equal ratex-key (latex-to-svg-backend--cache-key "$x$" 'ratex))))
    (let ((latex-to-svg-backend-ratex-macros "\\def\\v{\\mathbf{v}}"))
      (should-not (equal ratex-key (latex-to-svg-backend--cache-key "$x$" 'ratex))))))

(ert-deftest latex-to-svg-backend-unknown-engine-signals ()
  ;; A misspelt engine is reported, not quietly replaced by a default, by
  ;; every public function that takes one.
  (should-error (latex-to-svg-backend "$x$" :engine 'mathjax))
  (should-error (latex-to-svg-backend-tools-available-p 'mathjax))
  (should-error (latex-to-svg-backend-invalidate "$x$" 'mathjax))
  (should-error (latex-to-svg-backend-metadata "$x$" 'mathjax)))

(ert-deftest latex-to-svg-backend-tools-available-p-follows-engine ()
  ;; Each engine is available when its own programs are found.
  ;; Nil is the LaTeX engine.
  (let ((latex-to-svg-backend-latex-program "l2s-no-such-latex")
        (latex-to-svg-backend-ratex-program "emacs"))
    (should-not (latex-to-svg-backend-tools-available-p))
    (should-not (latex-to-svg-backend-tools-available-p 'latex))
    (should (latex-to-svg-backend-tools-available-p 'ratex))
    (let ((latex-to-svg-backend-ratex-program "l2s-no-such-render-svg"))
      (should-not (latex-to-svg-backend-tools-available-p 'ratex)))))

(ert-deftest latex-to-svg-backend-engine-is-per-call ()
  ;; `:engine' decides both the cache key and the compile, per call: the
  ;; same equation queued without it (the LaTeX engine) and with `ratex'
  ;; gets two entries and two different compiles.  `-invalidate' and
  ;; `-metadata' name the entry of the engine they are given.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-engine" t))
         (latex-to-svg-backend--pending (make-hash-table :test 'equal))
         (latex-to-svg-backend--queue nil)
         (latex-to-svg-backend--running nil)
         (latex-to-svg-backend-jobs 100)
         (latex-to-svg-backend-ratex-macros "")
         (doc "$x$")
         (latex-key (latex-to-svg-backend--cache-key doc 'latex))
         (ratex-key (latex-to-svg-backend--cache-key doc 'ratex))
         (compiled nil))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
                  ((symbol-function 'latex-to-svg-backend--compile)
                   (lambda (key &rest _) (push (cons 'latex key) compiled)))
                  ((symbol-function 'latex-to-svg-backend--ratex-compile)
                   (lambda (key &rest _) (push (cons 'ratex key) compiled))))
          (should-not (latex-to-svg-backend doc :callback #'ignore))
          (should-not (latex-to-svg-backend doc :callback #'ignore :engine 'ratex))
          (should (equal compiled (list (cons 'ratex ratex-key)
                                        (cons 'latex latex-key))))
          (dolist (key (list latex-key ratex-key))
            (with-temp-file (latex-to-svg-backend--svg-file key)
              (insert "<svg/>")))
          (with-temp-file (latex-to-svg-backend--meta-file latex-key)
            (prin1 '(:nums (1 . 1)) (current-buffer)))
          (should (equal (latex-to-svg-backend-metadata doc) '(:nums (1 . 1))))
          (should-not (latex-to-svg-backend-metadata doc 'ratex))
          (latex-to-svg-backend-invalidate doc 'ratex)
          (should-not (file-exists-p (latex-to-svg-backend--svg-file ratex-key)))
          (should (file-exists-p (latex-to-svg-backend--svg-file latex-key))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; RaTeX engine

(ert-deftest latex-to-svg-backend-ratex-formula-strips-delimiters ()
  ;; RaTeX rejects `\(' and `\[': the outer delimiter is removed, and it
  ;; chooses text or display style.  An environment is typeset as is.
  (let ((latex-to-svg-backend-ratex-macros ""))
    (dolist (case '(("$x$" "x" t)
                    ("\\(x\\)" "x" t)
                    ("$$x$$" "x" nil)
                    ("\\[ x \\]" "x" nil)
                    ("\\begin{equation}x\\end{equation}"
                     "\\begin{equation}x\\end{equation}" nil)
                    ("x^2" "x^2" nil)))
      (should (equal (latex-to-svg-backend--ratex-formula (nth 0 case))
                     (cons (nth 1 case) (nth 2 case)))))))

(ert-deftest latex-to-svg-backend-ratex-formula-is-one-line ()
  ;; `render-svg' reads one formula per line: comments go, lines are joined,
  ;; and the macros come first.  An escaped `%' is text, not a comment.
  (let ((latex-to-svg-backend-ratex-macros
         "\\def\\v{\\mathbf{v}} % bold\n\\def\\w{w}"))
    (should (equal (latex-to-svg-backend--ratex-formula
                    "\\begin{align}\na &= 5\\% \\\\ % first row\nb &= \\v\n\\end{align}")
                   (cons (concat "\\def\\v{\\mathbf{v}}  \\def\\w{w} "
                                 "\\begin{align} a &= 5\\% \\\\  b &= \\v "
                                 "\\end{align}")
                         nil))))
  ;; In `\\%' the backslash is escaped, so the `%' starts a comment.
  (should (equal (latex-to-svg-backend--ratex-one-line "a \\\\% gone\nb")
                 "a \\\\ b")))

(defconst latex-to-svg-backend-tests--ratex-output
  (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 20 10\" "
          "width=\"20pt\" height=\"10pt\">"
          "<path d=\"M1 -0.5 L5 2 Q6 9.5 3 4 Z\" fill=\"rgba(1,2,3,1)\" "
          "fill-rule=\"nonzero\" stroke=\"none\"/>"
          "<rect x=\"8\" y=\"3\" width=\"4\" height=\"1\" fill=\"rgba(1,2,3,1)\"/>"
          "<path d=\"M14 2 L16 6\" fill=\"none\" stroke=\"rgba(255,0,0,1)\" "
          "stroke-width=\"1\"/></svg>")
  "An SVG shaped like `render-svg' output: ink outside and inside the viewport.")

(ert-deftest latex-to-svg-backend-ratex-svg-crops-and-recolors ()
  ;; The viewport is moved to the ink, the default ink becomes
  ;; `currentColor', and a color of the formula's own stays.
  (let ((out (latex-to-svg-backend--ratex-svg
              latex-to-svg-backend-tests--ratex-output)))
    ;; x from 1 to 16.5 (the stroke grows the last path by 0.5), y from -0.5
    ;; to 9.5.
    (should (string-prefix-p
             (concat "<svg xmlns='http://www.w3.org/2000/svg' "
                     "width='15.5000pt' height='10.0000pt' "
                     "viewBox='1.0000 -0.5000 15.5000 10.0000'>")
             out))
    (should (= 3 (length (split-string out "currentColor"))))
    (should-not (string-search "rgba(1,2,3,1)" out))
    (should (string-search "stroke=\"rgba(255,0,0,1)\"" out))
    ;; The root is in the form `--pad-svg' reads.
    (should (string-search "width='17.5pt'"
                           (latex-to-svg-backend--pad-svg out 1 nil)))))

(ert-deftest latex-to-svg-backend-ratex-svg-keeps-empty-viewport ()
  ;; Nothing drawn: RaTeX's own viewport is kept.  No root: nil.
  (should (string-prefix-p
           (concat "<svg xmlns='http://www.w3.org/2000/svg' "
                   "width='3.0000pt' height='2.0000pt' "
                   "viewBox='0.0000 0.0000 3.0000 2.0000'>")
           (latex-to-svg-backend--ratex-svg
            "<svg viewBox=\"0 0 3 2\" width=\"3pt\" height=\"2pt\"></svg>")))
  (should-not (latex-to-svg-backend--ratex-svg "not an svg")))

(ert-deftest latex-to-svg-backend-ink-box-places-glyphs-and-transforms ()
  ;; pdftocairo's shape: a glyph is drawn once in <defs> and counts only
  ;; where a <use> places it; a rule is a stroked path with a matrix().
  (let ((svg (concat
              "<svg xmlns=\"http://www.w3.org/2000/svg\" "
              "xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
              "width=\"20pt\" height=\"20pt\" viewBox=\"0 0 20 20\">\n"
              "<defs>\n<g>\n<g id=\"glyph-0-0\">\n"
              "<path d=\"M 0 -4 L 3 -4 L 3 1 Z \"/>\n</g>\n</g>\n</defs>\n"
              "<g fill=\"rgb(0%, 0%, 0%)\" fill-opacity=\"1\">\n"
              "<use xlink:href=\"#glyph-0-0\" x=\"5\" y=\"10\"/>\n</g>\n"
              "<path fill=\"none\" stroke-width=\"0.4\" "
              "stroke=\"rgb(0%, 0%, 0%)\" d=\"M 0 0 L 4 0 \" "
              "transform=\"matrix(2, 0, 0, -2, 4, 14)\"/>\n</svg>\n")))
    ;; Glyph: x 5..8, y 6..11.  Rule: x 4..12 at y 14, grown by 0.4.
    (should (equal (mapcar (lambda (v) (/ (round (* v 1000)) 1000.0))
                           (latex-to-svg-backend--ink-box svg))
                   '(3.6 6.0 12.4 14.4)))
    (let ((out (latex-to-svg-backend--crop-to-ink
                svg (regexp-quote "rgb(0%, 0%, 0%)"))))
      ;; `<use xlink:href>' needs the namespace on the rewritten root.
      (should (string-prefix-p
               (concat "<svg xmlns='http://www.w3.org/2000/svg' "
                       "xmlns:xlink='http://www.w3.org/1999/xlink' "
                       "width='8.8000pt' height='8.4000pt' "
                       "viewBox='3.6000 6.0000 8.8000 8.4000'>")
               out))
      (should-not (string-search "rgb(0%, 0%, 0%)" out))
      (should (string-search "fill=\"currentColor\"" out)))))

(ert-deftest latex-to-svg-backend-ratex-compile-argv-and-store ()
  ;; `render-svg' is started directly with the formula file; its output is
  ;; stored cropped and recolored, the callbacks run, no `.eld' is written,
  ;; and the scratch directory and process buffer are removed.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((latex-to-svg-backend-ratex-program "ratex-direct")
           (latex-to-svg-backend-ratex-macros "")
           (doc "$x^2$")
           (key (latex-to-svg-backend--cache-key doc 'ratex))
           (callbacks 0))
      (latex-to-svg-backend--enqueue
       key doc (latex-to-svg-backend--waiter (lambda (_outcome) (cl-incf callbacks)))
       3 'ratex)
      (should (= (length l2s-test-processes) 1))
      (let* ((process (car l2s-test-processes))
             (plist (aref process 3))
             (scratch (aref process 4))
             (input (expand-file-name "equation.txt" scratch))
             (output-buffer (plist-get plist :buffer))
             (svg (latex-to-svg-backend--svg-file key)))
        (should (equal (plist-get plist :command)
                       (list "ratex-direct" "--input" input
                             "--output-dir" (directory-file-name scratch)
                             "--font-size" "40" "--dpr" "0.25"
                             "--padding" "0" "--color" "#010203"
                             "--inline")))
        ;; An inline formula gets the strut that puts its baseline at the
        ;; middle of RaTeX's SVG.
        (should (equal (latex-to-svg-backend-tests--tex-source input)
                       (concat "x^2 " latex-to-svg-backend--ratex-strut "\n")))
        (with-temp-file (expand-file-name "0001.svg" scratch)
          (insert latex-to-svg-backend-tests--ratex-output))
        (latex-to-svg-backend-tests--finish-fake-process process 0)
        (should (= callbacks 1))
        (with-temp-buffer
          (insert-file-contents svg)
          (should (search-forward "viewBox='1.0000 -0.5000" nil t))
          ;; The middle of the uncropped 10pt-high viewport.
          (should (search-forward "<!--latex-to-svg-backend-baseline 5.000000-->"
                                  nil t))
          (goto-char (point-min))
          (should (search-forward "<!--latex-to-svg-backend-x-height 4.310000-->"
                                  nil t))
          (should (search-forward "currentColor" nil t)))
        (should-not (file-exists-p (latex-to-svg-backend--meta-file key)))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should-not (buffer-live-p output-buffer))))))

(ert-deftest latex-to-svg-backend-ratex-failure-saves-process-output ()
  ;; RaTeX rejects the formula: its message is kept in the log next to the
  ;; SVG's place, a warning links to it, and the callback gets the failure.
  ;; An exit 0 without an SVG root fails the same way, but not because of
  ;; the formula.
  (dolist (outcome '(parse-error no-root))
    (latex-to-svg-backend-tests--with-fake-processes
      (let* ((latex-to-svg-backend-ratex-program "ratex-direct")
             (latex-to-svg-backend-ratex-macros "")
             (doc (format "$\\SI{%s}{m}$" outcome))
             (key (latex-to-svg-backend--cache-key doc 'ratex))
             (outcomes nil))
        (latex-to-svg-backend--enqueue
         key doc (latex-to-svg-backend--waiter (lambda (outcome) (push outcome outcomes)))
         nil 'ratex)
        (let* ((process (car l2s-test-processes))
               (scratch (aref process 4))
               (log (expand-file-name (concat key ".log")
                                      (latex-to-svg-backend--shard-dir key))))
          (if (eq outcome 'parse-error)
              (latex-to-svg-backend-tests--finish-fake-process
               process 1 (concat "ERR    1 \\SI{3}{m} — Parse error: ParseError at "
                                "position 0: Undefined control sequence: \\SI\n"))
            (with-temp-file (expand-file-name "0001.svg" scratch)
              (insert "garbage"))
            (latex-to-svg-backend-tests--finish-fake-process process 0))
          (should (equal outcomes
                         (list
                          (if (eq outcome 'parse-error)
                              (list :kind 'formula :engine 'ratex
                                    :message "ParseError at position 0: Undefined control sequence: \\SI"
                                    :line nil :column nil :log log :program nil)
                            (list :kind 'setup :engine 'ratex
                                  :message "The RaTeX engine wrote no SVG"
                                  :line nil :column nil :log log :program nil)))))
          (should-not (file-exists-p (latex-to-svg-backend--svg-file key)))
          (should-not (gethash key latex-to-svg-backend--pending))
          (should-not (file-directory-p scratch))
          (should l2s-test-warnings)
          (with-temp-buffer
            (insert-file-contents log)
            (should (search-forward (if (eq outcome 'parse-error)
                                        "Undefined control sequence"
                                      "output has no <svg> element")
                                    nil t))))))))

;;;; Failed compiles, the fallback engine, and quiet requests

(defconst latex-to-svg-backend-tests--ratex-parse-error
  (concat "ERR    1 \\SI{3}{m} — Parse error: ParseError at position 0: "
          "Undefined control sequence: \\SI\n")
  "What `render-svg' prints for a formula it cannot parse.")

(defmacro latex-to-svg-backend-tests--with-public-api (&rest body)
  "Run BODY with fake processes and no display needed.
A cached SVG is displayed as the symbol `image'."
  (declare (indent 0) (debug t))
  `(latex-to-svg-backend-tests--with-fake-processes
     (let ((latex-to-svg-backend-ratex-program "ratex-direct")
           (latex-to-svg-backend-ratex-macros "")
           (latex-to-svg-backend--image-cache (make-hash-table :test 'equal))
           (l2s-test-timers nil))
       (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
                 ((symbol-function 'latex-to-svg-backend--load-svg-image)
                  (lambda (&rest _) 'image))
                 ((symbol-function 'run-at-time)
                  (lambda (_time _repeat fn &rest args)
                    (setq l2s-test-timers
                          (nconc l2s-test-timers (list (cons fn args)))))))
         ,@body))))

(defmacro latex-to-svg-backend-tests--run-timers ()
  "Run the timers a test made, as the command loop would, oldest first."
  `(while l2s-test-timers
     (let ((timer (pop l2s-test-timers)))
       (apply (car timer) (cdr timer)))))

(defun latex-to-svg-backend-tests--fail-ratex (process)
  "Finish the fake RaTeX PROCESS as `render-svg' does on a parse error."
  (latex-to-svg-backend-tests--finish-fake-process
   process 1 latex-to-svg-backend-tests--ratex-parse-error))

(defun latex-to-svg-backend-tests--succeed-latex (process newest)
  "Finish the fake `latex' PROCESS and the `dvisvgm' one it starts.
NEWEST is a function returning the most recently started fake process."
  (with-temp-file (expand-file-name "equation.dvi" (aref process 4))
    (insert "fake dvi"))
  (latex-to-svg-backend-tests--finish-fake-process process 0)
  (let ((dvisvgm (funcall newest)))
    ;; dvisvgm's argv: PROGRAM FLAGS... -o SVG DVI.
    (with-temp-file (nth 6 (plist-get (aref dvisvgm 3) :command))
      (insert "<svg/>"))
    (latex-to-svg-backend-tests--finish-fake-process dvisvgm 0)))

(ert-deftest latex-to-svg-backend-parse-error-is-recorded-and-not-retried ()
  ;; RaTeX rejects the formula: the failure is recorded in the `.eld', and a
  ;; later request returns nil without compiling.  `-metadata' does not
  ;; return the record; `-invalidate' deletes it, so the next request
  ;; compiles again.
  (latex-to-svg-backend-tests--with-public-api
    (let* ((doc "$\\SI{3}{m}$")
           (key (latex-to-svg-backend--cache-key doc 'ratex))
           (outcomes nil))
      (should-not (latex-to-svg-backend doc :engine 'ratex :x-height 10
                                        :color "#000000"
                                        :callback (lambda (outcome) (push outcome outcomes))))
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (should (equal (mapcar (lambda (o) (plist-get o :kind)) outcomes) '(formula)))
      (should (equal (with-temp-buffer
                       (insert-file-contents (latex-to-svg-backend--meta-file key))
                       (read (current-buffer)))
                     '(:failed t :kind formula :engine ratex
                               :message "ParseError at position 0: Undefined control sequence: \\SI"
                               :line nil :column nil)))
      (should-not (latex-to-svg-backend-metadata doc 'ratex))
      (should (= 1 (length l2s-test-warnings)))
      ;; Known failure: no compile, no second warning in this buffer; the
      ;; callback gets the recorded failure, after the request returned.
      (should-not (latex-to-svg-backend doc :engine 'ratex :x-height 10
                                        :color "#000000"
                                        :callback (lambda (outcome) (push outcome outcomes))))
      (should (= 1 (length outcomes)))
      (latex-to-svg-backend-tests--run-timers)
      (should (= 2 (length outcomes)))
      (should (equal (car outcomes) (cadr outcomes)))
      (should (= 1 (length l2s-test-processes)))
      (should (= 1 (length l2s-test-warnings)))
      ;; The LaTeX engine's entry is another one.
      (should-not (latex-to-svg-backend--failed-p
                   (latex-to-svg-backend--cache-key doc 'latex)))
      (latex-to-svg-backend-invalidate doc 'ratex)
      (should-not (file-exists-p (latex-to-svg-backend--meta-file key)))
      (latex-to-svg-backend doc :engine 'ratex :x-height 10 :color "#000000"
                                :callback #'ignore)
      (should (= 2 (length l2s-test-processes)))
      ;; The warnings were forgotten too, so a failure that remains is
      ;; reported again.
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (should (= 2 (length l2s-test-warnings))))))

(ert-deftest latex-to-svg-backend-only-formula-errors-are-recorded ()
  ;; A crash, a missing output, or a killed process is not the formula's
  ;; fault: nothing is recorded, and the next request compiles again.  A
  ;; LaTeX error in the document is recorded, a disk error in its log not.
  (latex-to-svg-backend-tests--with-public-api
    (let ((cases
           `((ratex "$a$" ,(lambda (p) (latex-to-svg-backend-tests--finish-fake-process
                                        p 134 "thread 'main' panicked\n")))
             (ratex "$b$" ,(lambda (p) (latex-to-svg-backend-tests--finish-fake-process
                                        p 1 "Failed to write SVG\n")))
             (ratex "$c$" ,(lambda (p) (latex-to-svg-backend-tests--finish-fake-process
                                        p 6 nil 'signal)))
             (latex "$d$" ,(lambda (p) (latex-to-svg-backend-tests--finish-fake-process
                                        p 1 "latex: command failed\n")))
             (latex "$e$" ,(lambda (p)
                             (with-temp-file (expand-file-name "equation.log" (aref p 4))
                               (insert "! I can't write on file `equation.dvi'.\n"))
                             (latex-to-svg-backend-tests--finish-fake-process p 1)))
             (latex "$f$" ,(lambda (p)
                             (with-temp-file (expand-file-name "equation.dvi" (aref p 4))
                               (insert "fake dvi"))
                             (latex-to-svg-backend-tests--finish-fake-process p 0)
                             (latex-to-svg-backend-tests--finish-fake-process
                              (car l2s-test-processes) 1 "dvisvgm failed\n")))
             (latex "$\\undefined$"
                    ,(lambda (p)
                       (with-temp-file (expand-file-name "equation.log" (aref p 4))
                         (insert "! Undefined control sequence.\nl.3 $\\undefined\n"))
                       (latex-to-svg-backend-tests--finish-fake-process p 1))
                    recorded))))
      (pcase-dolist (`(,engine ,doc ,finish ,recorded) cases)
        (latex-to-svg-backend doc :engine engine :callback #'ignore)
        (funcall finish (car l2s-test-processes))
        (should (eq (and (latex-to-svg-backend--failed-p
                          (latex-to-svg-backend--cache-key doc engine))
                         t)
                    (and recorded t)))
        (let ((before (length l2s-test-processes)))
          (latex-to-svg-backend doc :engine engine :callback #'ignore)
          (should (= (length l2s-test-processes)
                     (if recorded before (1+ before)))))))))

(ert-deftest latex-to-svg-backend-falls-back-to-latex ()
  ;; With `:fallback latex', a formula RaTeX rejects is compiled with LaTeX
  ;; under LaTeX's key; the queued callback fires when that SVG lands, and
  ;; the re-query returns it, with no warning.  Without the fallback the
  ;; same request fails again.
  (latex-to-svg-backend-tests--with-public-api
    (let* ((doc "$\\SI{3}{m}$")
           (ratex-key (latex-to-svg-backend--cache-key doc 'ratex))
           (latex-key (latex-to-svg-backend--cache-key doc 'latex))
           (callbacks 0)
           (timers nil)
           (messages nil))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (should-not (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                                          :x-height 10 :color "#000000"
                                          :callback (lambda (_outcome) (cl-incf callbacks))))
        (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
        (should (latex-to-svg-backend--failed-p ratex-key))
        ;; The same string, now compiled by LaTeX.
        (should (= 2 (length l2s-test-processes)))
        (should (equal (car (plist-get (aref (car l2s-test-processes) 3) :command))
                       "latex-direct"))
        (should (= callbacks 0))
        (latex-to-svg-backend-tests--succeed-latex
         (car l2s-test-processes) (lambda () (car l2s-test-processes)))
        (should (= callbacks 1))
        (should (file-exists-p (latex-to-svg-backend--svg-file latex-key)))
        (should-not l2s-test-warnings)
        ;; The caller re-queries with the same arguments.
        (should (eq 'image (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                                                 :x-height 10 :color "#000000"
                                                 :callback #'ignore)))
        (should (eq 'latex (latex-to-svg-backend-engine-used doc 'ratex 'latex)))
        (should-not (latex-to-svg-backend-engine-used doc 'ratex))
        (should (= 3 (length l2s-test-processes)))
        ;; The fallback is announced once, for the buffer.
        (should (= 1 (length timers)))
        (apply (car (car timers)) (cdr (car timers)))
        (should (equal (car messages)
                       (format (concat "latex-to-svg-backend: 1 equation in %s "
                                       "fell back to LaTeX: RaTeX could not parse it")
                               (buffer-name))))
        (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                              :x-height 10 :color "#000000"
                              :callback #'ignore)
        (should (= 1 (length timers)))
        ;; Fallback off: no picture, no compile.
        (should-not (latex-to-svg-backend doc :engine 'ratex :x-height 10
                                          :color "#000000" :callback #'ignore))
        (should (= 3 (length l2s-test-processes)))))))

(ert-deftest latex-to-svg-backend-fallback-counts-per-buffer ()
  ;; The message counts the equations of one buffer that fell back.
  (with-temp-buffer
    (let ((messages nil) (timers nil))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (dolist (key '("k1" "k2" "k1" "k3"))
          (latex-to-svg-backend--note-fallback key 'ratex 'latex))
        (should (= 1 (length timers)))
        (apply (car (car timers)) (cdr (car timers)))
        (should (string-match-p "3 equations in .* fell back to LaTeX: RaTeX could not parse them"
                                (car messages)))
        (latex-to-svg-backend--note-fallback "k4" 'ratex 'latex)
        (should (= 1 (length timers)))))))

(ert-deftest latex-to-svg-backend-missing-program-warns-and-retries ()
  ;; A program that is not found: the request returns nil, one warning per
  ;; buffer names the engine and the program, even for a quiet request, and
  ;; nothing is recorded, so the next request runs the program again and
  ;; compiles once it is installed.
  (latex-to-svg-backend-tests--with-public-api
    (setq l2s-test-missing '("ratex-direct"))
    (let ((missing (lambda ()
                     (seq-count
                      (lambda (w)
                        (string-match-p
                         "The RaTeX engine could not run `ratex-direct': program not found"
                         (nth 1 w)))
                      l2s-test-warnings))))
      (should-not (latex-to-svg-backend "$x$" :engine 'ratex :quiet t
                                        :callback #'ignore))
      (should (= 1 (funcall missing)))
      (should (= 1 (length l2s-test-warnings)))
      (should-not (latex-to-svg-backend--failed-p
                   (latex-to-svg-backend--cache-key "$x$" 'ratex)))
      (should-not latex-to-svg-backend--running)
      (should-not (latex-to-svg-backend "$y$" :engine 'ratex :callback #'ignore))
      (should (= 1 (length l2s-test-warnings)))
      ;; Another buffer is told again.
      (with-temp-buffer
        (latex-to-svg-backend "$z$" :engine 'ratex :callback #'ignore))
      (should (= 2 (funcall missing)))
      (setq l2s-test-missing nil)
      (latex-to-svg-backend "$x$" :engine 'ratex :callback #'ignore)
      (should (= 1 (length l2s-test-processes))))))

(ert-deftest latex-to-svg-backend-missing-absolute-program ()
  ;; `make-process' starts an absolute file name that does not exist, and
  ;; the process exits with 127: that is reported as a missing program.
  ;; An existing program that exits with 127 is an ordinary failure.
  (latex-to-svg-backend-tests--with-fake-processes
    (let ((results nil))
      (dolist (program (list "/l2s-no-such-dir/latex"
                             (expand-file-name invocation-name
                                               invocation-directory)))
        (let ((buffer (generate-new-buffer " *l2s-127*")))
          (latex-to-svg-backend--run-process-chain
           "l2s-127" temporary-file-directory buffer
           (list (list 'latex (list program) "out"))
           (lambda (_success &optional exit) (push exit results)))
          (latex-to-svg-backend-tests--finish-fake-process
           (car l2s-test-processes) 127)))
      (should (equal (nreverse results)
                     (list '(latex . "/l2s-no-such-dir/latex")
                           '(latex . 127)))))))

(ert-deftest latex-to-svg-backend-fallback-program-missing ()
  ;; The fallback engine's program is not found: the RaTeX failure is
  ;; recorded and the request handed to LaTeX, whose start fails; the
  ;; warning names the LaTeX engine and its program.  The next request
  ;; tries LaTeX again from the record.
  (latex-to-svg-backend-tests--with-public-api
    (setq l2s-test-missing '("latex-direct"))
    (latex-to-svg-backend "$\\SI{1}{m}$" :engine 'ratex :fallback 'latex
                          :callback #'ignore)
    (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
    (should (latex-to-svg-backend--failed-p
             (latex-to-svg-backend--cache-key "$\\SI{1}{m}$" 'ratex)))
    (should (= 1 (length l2s-test-warnings)))
    (should (string-match-p "The LaTeX engine could not run `latex-direct'"
                            (nth 1 (car l2s-test-warnings))))
    (setq l2s-test-missing nil)
    (should-not (latex-to-svg-backend "$\\SI{1}{m}$" :engine 'ratex
                                      :fallback 'latex :callback #'ignore))
    (should (= 2 (length l2s-test-processes)))
    (should (equal (car (plist-get (aref (car l2s-test-processes) 3) :command))
                   "latex-direct"))))

(ert-deftest latex-to-svg-backend-missing-converter-is-reported ()
  ;; `dvisvgm' is not found after `latex' ran: the missing program is
  ;; reported, and nothing runs again.
  (latex-to-svg-backend-tests--with-public-api
    (setq l2s-test-missing '("dvisvgm-direct"))
    (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
               (lambda (&rest _) "/tmp/l2s-fake.fmt")))
      (latex-to-svg-backend "$x$" :callback #'ignore)
      (let ((latex (car l2s-test-processes)))
        (with-temp-file (expand-file-name "equation.dvi" (aref latex 4))
          (insert "fake dvi"))
        (latex-to-svg-backend-tests--finish-fake-process latex 0))
      (should (= 1 (length l2s-test-processes)))
      (should-not latex-to-svg-backend--running)
      (should (string-match-p "could not run `dvisvgm-direct'"
                              (nth 1 (car l2s-test-warnings)))))))

(ert-deftest latex-to-svg-backend-missing-tex-program-writes-no-stamp ()
  ;; A TeX program that is not found cannot dump the `.fmt' file: no
  ;; `.fmt' file, no stamp and no warning from the dump, so the dump runs
  ;; once the program is installed.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-missing" t))
         (latex-to-svg-backend-precompile t)
         (latex-to-svg-backend-latex-program "l2s-no-such-latex")
         (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
         (warnings nil))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest w) (push w warnings))))
          (should-not (latex-to-svg-backend--ensure-format "\\documentclass{article}"))
          (should-not warnings)
          (should-not (directory-files (latex-to-svg-backend--fmt-dir) nil
                                       "\\.\\(?:tex\\|eld\\)\\'")))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-failed-dump-compiles-nothing ()
  ;; While the dump of the preamble has failed, a request runs no process
  ;; and records nothing; its callback gets a `setup' failure with the
  ;; dump's log, after the request returns.  A tentative request too.
  (latex-to-svg-backend-tests--with-public-api
    (let ((log (expand-file-name "fmt/abc.log" l2s-test-cache-dir))
          (outcomes nil))
      (make-directory (file-name-directory log) t)
      (with-temp-file log (insert "! Undefined control sequence.\n"))
      (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                 (lambda (&rest _) (cons 'failed log))))
        (latex-to-svg-backend "$x$" :callback (lambda (o) (push o outcomes)))
        (latex-to-svg-backend "$y$" :tentative t
                              :callback (lambda (o) (push o outcomes)))
        (should-not outcomes)
        (latex-to-svg-backend-tests--run-timers)
        (should (= 2 (length outcomes)))
        (dolist (outcome outcomes)
          (should (eq (plist-get outcome :kind) 'setup))
          (should (eq (plist-get outcome :engine) 'latex))
          (should (equal (plist-get outcome :log) log))
          (should (string-match-p "could not precompile the preamble"
                                  (plist-get outcome :message))))
        (should-not l2s-test-processes)
        (should-not latex-to-svg-backend--running)
        (should-not (file-exists-p (latex-to-svg-backend--meta-file
                                    (latex-to-svg-backend--cache-key "$x$"))))
        (should-not l2s-test-warnings)))))
(ert-deftest latex-to-svg-backend-texres-missing-runs-by-name ()
  ;; Without texres there is no link, and texres is run by its own name,
  ;; so its start fails as any missing program's does.
  (let ((latex-to-svg-backend-texres-program "l2s-no-such-texres"))
    (should (equal (plist-get (latex-to-svg-backend--texres-toolchain) :program)
                   "l2s-no-such-texres"))))

(defmacro latex-to-svg-backend-tests--with-fake-texres (&rest body)
  "Run BODY with `texres', the name of a fake texres in an empty cache.
BODY writes it (see `latex-to-svg-backend-tests--write-texres').  No
version is read yet; warnings are collected in `warnings'."
  (declare (indent 0) (debug t))
  `(let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-texres" t))
          (latex-to-svg-backend--texres-versions (make-hash-table :test 'equal))
          (texres (expand-file-name "fake-texres" latex-to-svg-backend-cache-directory))
          (latex-to-svg-backend-texres-program texres)
          (warnings nil))
     (unwind-protect
         (cl-letf (((symbol-function 'display-warning)
                    (lambda (&rest w) (push w warnings))))
           (with-temp-buffer
             ,@body))
       (delete-directory latex-to-svg-backend-cache-directory t))))

(defun latex-to-svg-backend-tests--write-texres (file output)
  "Write FILE, an executable script that prints OUTPUT."
  (with-temp-file file
    (insert "#!/bin/sh\nprintf '%s\\n' '" output "'\n"))
  (set-file-modes file #o755))

(ert-deftest latex-to-svg-backend-texres-command-by-version ()
  ;; From 0.7.8 texres takes `-progname=pdflatex'; 0.7.7 runs through the
  ;; link and warns once per buffer; an unknown version takes the argument.
  (skip-unless (executable-find "sh"))
  (latex-to-svg-backend-tests--with-fake-texres
    (latex-to-svg-backend-tests--write-texres texres "texres 0.7.8 (Rust TeX engine)")
    (should (equal (latex-to-svg-backend--texres-command)
                   (list texres "-progname=pdflatex")))
    (should-not warnings)
    (clrhash latex-to-svg-backend--texres-versions)
    (latex-to-svg-backend-tests--write-texres texres "texres 0.7.7 (Rust TeX engine)")
    (let ((link (expand-file-name "texres/pdflatex"
                                  latex-to-svg-backend-cache-directory)))
      (should (equal (latex-to-svg-backend--texres-command) link))
      (should (equal (latex-to-svg-backend--texres-command) link)))
    (should (= (length warnings) 1))
    (should (string-search "Install texres 0.7.8 or later" (cadr (car warnings))))
    (clrhash latex-to-svg-backend--texres-versions)
    (latex-to-svg-backend-tests--write-texres texres "something else")
    (should (equal (latex-to-svg-backend--texres-command)
                   (list texres "-progname=pdflatex")))))

(ert-deftest latex-to-svg-backend-texres-version-is-read-again-after-an-upgrade ()
  ;; The version is read once per binary; a new modification time, as
  ;; after an upgrade, reads it again.
  (skip-unless (executable-find "sh"))
  (latex-to-svg-backend-tests--with-fake-texres
    (latex-to-svg-backend-tests--write-texres texres "texres 0.7.7 (Rust TeX engine)")
    (set-file-times texres (seconds-to-time 1000000000))
    (should (equal (latex-to-svg-backend--texres-version texres) "0.7.7"))
    (latex-to-svg-backend-tests--write-texres texres "texres 0.7.8 (Rust TeX engine)")
    (set-file-times texres (seconds-to-time 1000000000))
    (should (equal (latex-to-svg-backend--texres-version texres) "0.7.7"))
    (set-file-times texres)
    (should (equal (latex-to-svg-backend--texres-version texres) "0.7.8"))))

(ert-deftest latex-to-svg-backend-texres-version-unknown-when-it-cannot-run ()
  ;; A texres that cannot be run has no version, and none is kept, so it
  ;; is read again once texres runs.
  (latex-to-svg-backend-tests--with-fake-texres
    (with-temp-file texres (insert "not run"))
    (set-file-modes texres #o644)
    (should-not (latex-to-svg-backend--texres-version texres))
    (should (zerop (hash-table-count latex-to-svg-backend--texres-versions)))))

(ert-deftest latex-to-svg-backend-tex-command-takes-arguments ()
  ;; A TeX program is a name or a list of the program and its first
  ;; arguments; as in TeX, `-progname=NAME' names the `.fmt' file.
  (let ((latex-to-svg-backend-latex-program "latex"))
    (should (equal (latex-to-svg-backend--tex-command) '("latex")))
    (should (equal (latex-to-svg-backend--latex-format-name) "latex"))
    (should (equal (latex-to-svg-backend--latex-format-name "/a/pdflatex")
                   "pdflatex"))
    (should (equal (latex-to-svg-backend--latex-format-name
                    '("/a/texres" "-progname=pdflatex"))
                   "pdflatex"))
    ;; The key of the default program is a string's, as before.
    (should (equal (latex-to-svg-backend--format-key "p")
                   (secure-hash 'sha1 "p\0latex")))
    (should-not (equal (latex-to-svg-backend--format-key "p" '("/a/texres"))
                       (latex-to-svg-backend--format-key "p" "/a/texres")))))

(ert-deftest latex-to-svg-backend-failure-warns-per-requesting-buffer ()
  ;; Two buffers wait on one compile: each is told, by name.  A killed one
  ;; is skipped, a quiet one is not told, and with no requesting buffer
  ;; left nobody is.
  (latex-to-svg-backend-tests--with-public-api
    (let ((a (generate-new-buffer "notes.md"))
          (b (generate-new-buffer "chat"))
          (c (generate-new-buffer "quiet"))
          (d (generate-new-buffer "gone")))
      (unwind-protect
          (progn
            (dolist (buffer (list a b c d))
              (with-current-buffer buffer
                (latex-to-svg-backend "$\\SI{3}{m}$" :engine 'ratex
                                      :quiet (eq buffer c) :callback #'ignore)))
            (should (= 1 (length l2s-test-processes)))
            (kill-buffer d)
            (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
            (should (equal (sort (mapcar (lambda (w)
                                           (and (string-match "\\`\\([^:]+\\): " (nth 1 w))
                                                (match-string 1 (nth 1 w))))
                                         l2s-test-warnings)
                                 #'string<)
                           '("chat" "notes.md")))
            ;; The display path reports a known failure again in a new
            ;; document, once.
            (with-temp-buffer
              (latex-to-svg-backend "$\\SI{3}{m}$" :engine 'ratex :callback #'ignore)
              (latex-to-svg-backend "$\\SI{3}{m}$" :engine 'ratex :callback #'ignore)
              (should (= 3 (length l2s-test-warnings))))
            ;; Every requesting buffer killed: no warning.
            (let ((e (generate-new-buffer "e")))
              (with-current-buffer e
                (latex-to-svg-backend "$\\SI{4}{m}$" :engine 'ratex :callback #'ignore))
              (kill-buffer e)
              (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
              (should (= 3 (length l2s-test-warnings)))))
        (mapc #'kill-buffer (seq-filter #'buffer-live-p (list a b c)))))))

(ert-deftest latex-to-svg-backend-failure-warns-once-per-equation ()
  ;; Two different failing equations in one buffer: two warnings, each once.
  (latex-to-svg-backend-tests--with-public-api
    (dolist (doc '("$\\SI{1}{m}$" "$\\SI{2}{m}$" "$\\SI{1}{m}$" "$\\SI{2}{m}$"))
      (latex-to-svg-backend doc :engine 'ratex :callback #'ignore)
      (when (eq 'run (aref (car l2s-test-processes) 1))
        (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))))
    (should (= 2 (length l2s-test-processes)))
    (should (= 2 (length l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-gc-collects-failed-entries ()
  ;; A failed compile leaves an entry with no SVG: its `.eld' record or its
  ;; `.log'.  Those age out too, by their own mtime.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-failed" t))
        (latex-to-svg-backend-cache-max-age 30))
    (unwind-protect
        (let* ((old-time (seconds-to-time (- (float-time) (* 90 86400))))
               (file (lambda (doc ext)
                       (let ((f (concat (file-name-sans-extension
                                         (latex-to-svg-backend--svg-file
                                          (latex-to-svg-backend--cache-key doc)))
                                        ext)))
                         (with-temp-file f (insert "x"))
                         f)))
               (old-eld (funcall file "$old-eld$" ".eld"))
               (old-log (funcall file "$old-eld$" ".log"))
               (only-log (funcall file "$only-log$" ".log"))
               (new-eld (funcall file "$new-eld$" ".eld")))
          (dolist (f (list old-eld old-log only-log))
            (set-file-times f old-time))
          (should (equal (car (latex-to-svg-backend-gc)) 2))
          (should-not (file-exists-p old-eld))
          (should-not (file-exists-p old-log))
          (should-not (file-exists-p only-log))
          (should (file-exists-p new-eld)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; The outcome of a request

(defun latex-to-svg-backend-tests--fail-latex (process latex message line text)
  "Finish the fake `latex' PROCESS on an error in LATEX.
MESSAGE follows `! ' in the log, and TEXT follows `l.N ', N being
LINE of LATEX counted in the source the compile wrote."
  (let* ((tex (latex-to-svg-backend-tests--tex-file process))
         (lines (split-string (latex-to-svg-backend-tests--tex-source tex) "\n"))
         (first (seq-position lines (car (split-string latex "\n")))))
    (with-temp-file (expand-file-name "equation.log" (aref process 4))
      (insert (format "! %s\nl.%d %s\n" message (+ first line) text)))
    (latex-to-svg-backend-tests--finish-fake-process process 1)))

(ert-deftest latex-to-svg-backend-callback-gets-nil-once-the-svg-is-cached ()
  ;; The callback is called once, with nil; the caller asks again.
  (latex-to-svg-backend-tests--with-public-api
    (let ((outcomes nil))
      (should-not (latex-to-svg-backend "$x$" :x-height 10 :color "#000000"
                                        :callback (lambda (o) (push o outcomes))))
      (latex-to-svg-backend-tests--succeed-latex
       (car l2s-test-processes) (lambda () (car l2s-test-processes)))
      (latex-to-svg-backend-tests--run-timers)
      (should (equal outcomes '(nil)))
      (should (eq 'image (latex-to-svg-backend "$x$" :x-height 10 :color "#000000"
                                               :callback #'ignore))))))

(ert-deftest latex-to-svg-backend-callback-gets-the-formula-error ()
  ;; A LaTeX error in the formula: every waiter gets the failure, the
  ;; quiet one too, which is not warned.  After a restart the recorded
  ;; failure is the same plist, given after the request returned.
  (latex-to-svg-backend-tests--with-public-api
    (let* ((doc "$a +\n b + \\undefined$")
           (key (latex-to-svg-backend--cache-key doc))
           (loud nil)
           (quiet nil)
           (expected (list :kind 'formula :engine 'latex
                           :message "Undefined control sequence."
                           :line 2 :column 15
                           :log (latex-to-svg-backend--log-file key)
                           :program nil)))
      (latex-to-svg-backend doc :callback (lambda (o) (push o loud)))
      (latex-to-svg-backend doc :quiet t :callback (lambda (o) (push o quiet)))
      (should (= 1 (length l2s-test-processes)))
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 2
       " b + \\undefined")
      (should (equal loud (list expected)))
      (should (equal quiet (list expected)))
      (should (= 1 (length l2s-test-warnings)))
      ;; As in a new session.
      (setq loud nil)
      (with-temp-buffer
        (should-not (latex-to-svg-backend doc :quiet t
                                          :callback (lambda (o) (push o loud))))
        (should-not loud)
        (latex-to-svg-backend-tests--run-timers)
        (should (equal loud (list expected))))
      (should (= 1 (length l2s-test-processes))))))

(ert-deftest latex-to-svg-backend-callback-gets-a-setup-failure ()
  ;; Not the formula's fault: a crash, or a program not found.  Nothing is
  ;; recorded.  A program not found fails as the compile starts, inside
  ;; the request, so the callback comes after the request returned.
  (latex-to-svg-backend-tests--with-public-api
    (let ((outcomes nil))
      (latex-to-svg-backend "$a$" :engine 'ratex
                            :callback (lambda (o) (push o outcomes)))
      (latex-to-svg-backend-tests--finish-fake-process
       (car l2s-test-processes) 134 "thread 'main' panicked\n")
      (should (equal (seq-take (car outcomes) 6)
                     '(:kind setup :engine ratex
                             :message "The RaTeX engine failed: ratex exited with status 134")))
      (should-not (latex-to-svg-backend--failed-p
                   (latex-to-svg-backend--cache-key "$a$" 'ratex)))
      (setq outcomes nil
            l2s-test-missing '("ratex-direct"))
      (should-not (latex-to-svg-backend "$b$" :engine 'ratex :quiet t
                                        :callback (lambda (o) (push o outcomes))))
      (should-not outcomes)
      (latex-to-svg-backend-tests--run-timers)
      (should (= 1 (length outcomes)))
      (should (eq 'setup (plist-get (car outcomes) :kind)))
      (should (equal "ratex-direct" (plist-get (car outcomes) :program)))
      (should (equal (plist-get (car outcomes) :message)
                     "The RaTeX engine could not run `ratex-direct': program not found.")))))

(ert-deftest latex-to-svg-backend-callback-gets-the-fallbacks-outcome ()
  ;; With a fallback, the failure the callback gets is the fallback's: the
  ;; last engine that tried.  A later request finds both records and
  ;; gets the fallback's from a timer.
  (latex-to-svg-backend-tests--with-public-api
    (let ((doc "$\\SI{3}{m}$")
          (outcomes nil))
      (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                            :callback (lambda (o) (push o outcomes)))
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (should-not outcomes)
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 1 "$\\SI")
      (should (= 1 (length outcomes)))
      (should (equal (seq-take (car outcomes) 10)
                     '(:kind formula :engine latex
                             :message "Undefined control sequence."
                             :line 1 :column 4)))
      (setq outcomes nil)
      (should-not (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                                        :callback (lambda (o) (push o outcomes))))
      (latex-to-svg-backend-tests--run-timers)
      (should (eq 'latex (plist-get (car outcomes) :engine)))
      (should (= 2 (length l2s-test-processes))))))

(ert-deftest latex-to-svg-backend-failure-reads-the-records ()
  ;; ENGINE's failure, or FALLBACK's when FALLBACK failed too; nil when
  ;; either has a picture or nothing is recorded.
  (latex-to-svg-backend-tests--with-public-api
    (let ((record (lambda (doc engine message)
                    (latex-to-svg-backend--record-failure
                     (latex-to-svg-backend--cache-key doc engine)
                     (latex-to-svg-backend--failure 'formula engine :message message))))
          (svg (lambda (doc engine)
                 (with-temp-file (latex-to-svg-backend--svg-file
                                  (latex-to-svg-backend--cache-key doc engine))
                   (insert "<svg/>"))))
          (message (lambda (doc &rest args)
                     (plist-get (apply #'latex-to-svg-backend-failure doc args)
                                :message))))
      (should-not (latex-to-svg-backend-failure "$a$"))
      (funcall svg "$a$" 'latex)
      (should-not (latex-to-svg-backend-failure "$a$"))
      (funcall record "$b$" 'ratex "RaTeX: bad.")
      (should (equal (latex-to-svg-backend-failure "$b$" 'ratex)
                     '(:kind formula :engine ratex :message "RaTeX: bad."
                             :line nil :column nil :log nil :program nil)))
      ;; The fallback has not compiled it yet.
      (should-not (latex-to-svg-backend-failure "$b$" 'ratex 'latex))
      (should (equal (funcall message "$b$" 'ratex 'ratex) "RaTeX: bad."))
      (funcall record "$b$" 'latex "LaTeX: bad.")
      (should (equal (funcall message "$b$" 'ratex 'latex) "LaTeX: bad."))
      (funcall record "$c$" 'ratex "RaTeX: bad.")
      (funcall svg "$c$" 'latex)
      (should-not (latex-to-svg-backend-failure "$c$" 'ratex 'latex))
      (should (equal (funcall message "$c$" 'ratex) "RaTeX: bad.")))))

(ert-deftest latex-to-svg-backend-fall-back-answers-from-the-cache ()
  ;; A fallback whose SVG or failure record is there already is not
  ;; compiled: the callback gets nil, or the recorded failure.
  (latex-to-svg-backend-tests--with-public-api
    (let* ((outcomes nil)
           (waiter (latex-to-svg-backend--waiter (lambda (o) (push o outcomes)))))
      (with-temp-file (latex-to-svg-backend--svg-file
                       (latex-to-svg-backend--cache-key "$x$" 'latex))
        (insert "<svg/>"))
      (latex-to-svg-backend--fall-back "$x$" 'latex nil waiter nil)
      (latex-to-svg-backend--record-failure
       (latex-to-svg-backend--cache-key "$y$" 'latex)
       (latex-to-svg-backend--failure 'formula 'latex :message "Bad."))
      (latex-to-svg-backend--fall-back "$y$" 'latex nil waiter nil)
      (should (equal (mapcar (lambda (o) (plist-get o :message)) outcomes)
                     '("Bad." nil)))
      (should (equal (cadr outcomes) nil))
      (should-not l2s-test-processes))))

(ert-deftest latex-to-svg-backend-compile-that-cannot-start-tells-its-waiters ()
  ;; A compile that signals as it starts gives a setup failure of its
  ;; engine.
  (let ((latex-to-svg-backend--pending (make-hash-table :test 'equal))
        (latex-to-svg-backend--queue nil)
        (latex-to-svg-backend--running nil)
        (outcomes nil))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (puthash "a" (list (latex-to-svg-backend--waiter (lambda (o) (push o outcomes))))
               latex-to-svg-backend--pending)
      (latex-to-svg-backend--schedule
       "a" (lambda () (error "No scratch directory")) 'texres)
      (should (equal outcomes
                     '((:kind setup :engine texres
                              :message "The texres engine could not start a compile: No scratch directory"
                              :line nil :column nil :log nil :program nil)))))))

(ert-deftest latex-to-svg-backend-no-svg-support-is-a-setup-failure ()
  ;; Without SVG support nothing compiles, and the callback gets the
  ;; failure after the request returned.
  (let ((timers nil)
        (outcomes nil))
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'ignore)
              ((symbol-function 'display-warning) #'ignore)
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args) (push (cons fn args) timers))))
      (should-not (latex-to-svg-backend "$x$" :engine 'ratex
                                        :callback (lambda (o) (push o outcomes))))
      (should-not outcomes)
      (dolist (timer timers) (apply (car timer) (cdr timer)))
      (should (equal outcomes
                     (list (list :kind 'setup :engine 'ratex
                                 :message latex-to-svg-backend--no-svg-message
                                 :line nil :column nil :log nil :program nil)))))))

;;;; Where TeX stopped

(defun latex-to-svg-backend-tests--formula-error (log latex offset)
  "Return what the LaTeX engine reads from LOG, written as UTF-8.
LATEX and OFFSET are as for `latex-to-svg-backend--latex-formula-error'."
  (let ((dir (make-temp-file "l2s-tex-log" t)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region log nil (expand-file-name "equation.log" dir)))
          (latex-to-svg-backend--latex-formula-error dir latex offset))
      (delete-directory dir t))))

(ert-deftest latex-to-svg-backend-latex-formula-error-reads-the-log ()
  ;; Log excerpts from TeX Live 2026's `latex' and texres 0.7.7.  The line
  ;; counts in LATEX; the column is where TeX split the `l.N' line,
  ;; counted in characters; nil when TeX cut the line short or named no
  ;; line in LATEX.
  (let* ((long "$a_{11} + a_{12} + a_{13} + a_{14} + a_{15} + a_{16} + \\notacommand + b_1$")
         (stop (- (length long) (length " + b_1$"))))
    (pcase-dolist (`(,log ,latex ,offset ,expected)
                   `(;; With `latex-to-svg-backend--latex-environment'.
                     (,(concat "! Undefined control sequence.\n"
                               "l.6 " (substring long 0 stop) "\n"
                               (make-string (+ 4 stop) ?\s) " + b_1$\n"
                               "The control sequence at the end of the top line\n")
                      ,long 5
                      (:message "Undefined control sequence." :line 1 :column ,stop))
                     ;; Without it, or from texres: the line is cut short.
                     (,(concat "! Undefined control sequence.\n"
                               "l.6 ...} + a_{14} + a_{15} + a_{16} + \\notacommand\n"
                               "                                                   + b_1$\n")
                      ,long 5
                      (:message "Undefined control sequence." :line 1 :column nil))
                     ;; pdfTeX prints the bytes of a non-ASCII character.
                     ("! Undefined control sequence.\nl.4 $\\text{é} + \\notacommand\n   $\n"
                      "$\\text{é} + \\notacommand$" 3
                      (:message "Undefined control sequence." :line 1 :column 24))
                     ;; The second line of LATEX.
                     ("! Undefined control sequence.\nl.5 a = \\undefined\n\n"
                      "\\begin{equation}\na = \\undefined\n\\end{equation}" 3
                      (:message "Undefined control sequence." :line 2 :column 14))
                     ;; LaTeX breaks a long message onto indented lines.
                     (,(concat "! LaTeX Error: Unicode character α (U+03B1)\n"
                               "               not set up for use with LaTeX.\n"
                               "\n"
                               "See the LaTeX manual or LaTeX Companion for explanation.\n"
                               "Type  H <return>  for immediate help.\n"
                               " ...\n"
                               "\n"
                               "l.4 $x^2 + α\n"
                               "             β$\n")
                      "$x^2 + αβ$" 3
                      (:message ,(concat "LaTeX Error: Unicode character α (U+03B1)"
                                         " not set up for use with LaTeX.")
                                :line 1 :column 8))
                     ;; TeX names a line after LATEX.
                     (,(concat "! Missing $ inserted.\n<inserted text> \n"
                               "                $\nl.5 \\end{document}\n")
                      "$x^2 + y" 3
                      (:message "Missing $ inserted." :line nil :column nil))
                     ;; TeX names no line; the next `! ' line is not this
                     ;; error's.
                     (,(concat "! File ended while scanning use of \\frac .\n"
                               "<inserted text> \n                \\par \n"
                               "<*> equation.tex\n\n"
                               "! ==> Fatal error occurred, no output DVI file produced!\n"
                               "l.4 $x$\n")
                      "$\\frac{1}{$" 3
                      (:message "File ended while scanning use of \\frac ."
                                :line nil :column nil))
                     ;; Not the input's fault, or no error at all.
                     ("! I can't write on file `equation.dvi'.\n" "$x$" 3 nil)
                     ("This is pdfTeX, Version 3.141592653-2.6-1.40.28\n" "$x$" 3 nil)))
      (should (equal (latex-to-svg-backend-tests--formula-error log latex offset)
                     expected)))))

(ert-deftest latex-to-svg-backend-ratex-formula-error-reads-the-output ()
  ;; The message is RaTeX's; it gives no line or column in LATEX.  A disk
  ;; error, a panic or another exit status is not the formula's fault.
  (let ((output (concat "[ratex] (\"render-svg\" \"--input\" \"equation.txt\")\n"
                        latex-to-svg-backend-tests--ratex-parse-error
                        "[ratex] status=exit exit-status=1 event=\"exited\"\n")))
    (should (equal (latex-to-svg-backend--ratex-formula-error '(ratex . 1) output)
                   '(:message "ParseError at position 0: Undefined control sequence: \\SI"
                              :line nil :column nil)))
    (should-not (latex-to-svg-backend--ratex-formula-error
                 '(ratex . 1) "Failed to write SVG\n"))
    (should-not (latex-to-svg-backend--ratex-formula-error '(ratex . 134) output))
    (should-not (latex-to-svg-backend--ratex-formula-error nil output))))

;; The failure record

(ert-deftest latex-to-svg-backend-failure-record-holds-the-plist ()
  ;; The record holds what the engine read from its log, and reads back
  ;; with the saved log's path.  It is written as UTF-8, since a message
  ;; can quote the equation.  A record from 0.14.0 reads with nil fields.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-record" t))
         (dir (make-temp-file "l2s-record-src" t))
         (key (latex-to-svg-backend--cache-key "$x^2 + \u03b1$"))
         (old (latex-to-svg-backend--cache-key "$old$"))
         (message "LaTeX Error: Unicode character \u03b1 (U+03B1) not set up for use with LaTeX."))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (concat "! " message "\n") nil
                          (expand-file-name "equation.log" dir)))
          (let ((coding-system-for-write nil)
                (select-safe-coding-system-function
                 (lambda (&rest _)
                   (error "coding system not pinned: the write would have prompted"))))
            (cl-letf (((symbol-function 'display-warning) #'ignore))
              (latex-to-svg-backend--compile-failed
               key "$x^2 + \u03b1$" dir "" 'latex
               (list :message message :line 1 :column 8))))
          (should (latex-to-svg-backend--failed-p key))
          (should (equal (latex-to-svg-backend--recorded-failure key 'latex)
                         (list :kind 'formula :engine 'latex :message message
                               :line 1 :column 8
                               :log (latex-to-svg-backend--log-file key)
                               :program nil)))
          (should-not (latex-to-svg-backend-metadata "$x^2 + \u03b1$"))
          (with-temp-file (latex-to-svg-backend--meta-file old)
            (prin1 '(:failed t) (current-buffer)))
          (should (equal (latex-to-svg-backend--recorded-failure old 'ratex)
                         '(:kind formula :engine ratex :message nil :line nil
                                 :column nil :log nil :program nil)))
          (should-not (latex-to-svg-backend--recorded-failure
                       (latex-to-svg-backend--cache-key "$none$") 'latex)))
      (delete-directory dir t)
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-compile-counts-lines-before-the-equation ()
  ;; `--compile' gives the parser the number of lines before LATEX in
  ;; `equation.tex', with the full preamble, the macros text and a
  ;; toolchain prefix; `latex' runs with the environment that prints the
  ;; whole line, and `dvisvgm' without it.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((latex-to-svg-backend-preamble-not-precompiled "\\def\\a{a}\n\\def\\b{b}")
           (doc "$x +\n\\undefined$")
           (key (latex-to-svg-backend--cache-key doc))
           (faults nil))
      (cl-letf (((symbol-function 'latex-to-svg-backend--compile-failed)
                 (lambda (_key _latex _dir &optional _output _engine fault _exit)
                   (push fault faults))))
        (dolist (toolchain (list nil
                                 (append '(:prefix "\\relax\n\\relax\n")
                                         (latex-to-svg-backend--latex-toolchain))))
          (latex-to-svg-backend--compile key doc nil nil toolchain)
          (let* ((process (car l2s-test-processes))
                 (tex (latex-to-svg-backend-tests--tex-file process))
                 (lines (split-string (latex-to-svg-backend-tests--tex-source tex)
                                      "\n"))
                 (n (1+ (seq-position lines "\\undefined$"))))
            (should (member "max_print_line=1000" (aref process 5)))
            (with-temp-file (expand-file-name "equation.log" (aref process 4))
              (insert (format "! Undefined control sequence.\nl.%d \\undefined\n" n)))
            (latex-to-svg-backend-tests--finish-fake-process process 1)
            (should (equal (pop faults)
                           '(:message "Undefined control sequence."
                                      :line 2 :column 10)))))
        ;; The converter does not get the TeX settings.
        (latex-to-svg-backend--compile key doc)
        (let ((latex (car l2s-test-processes)))
          (with-temp-file (expand-file-name "equation.dvi" (aref latex 4))
            (insert "fake dvi"))
          (latex-to-svg-backend-tests--finish-fake-process latex 0))
        (should-not (member "max_print_line=1000"
                            (aref (car l2s-test-processes) 5)))))))

(ert-deftest latex-to-svg-backend-docstrings-show-delimiters ()
  ;; `C-h f' reads `\\[' as the start of a key reference, so a docstring that
  ;; means the LaTeX delimiter writes `\\=\\['.  Checked over every docstring.
  (mapatoms
   (lambda (sym)
     (when (string-prefix-p "latex-to-svg-backend" (symbol-name sym))
       (dolist (doc (list (and (fboundp sym) (documentation sym t))
                          (documentation-property sym 'variable-documentation t)))
         (when (stringp doc)
           (should-not (string-match-p "M-x\\|Uses keymap"
                                       (substitute-command-keys doc)))))))))

(defconst latex-to-svg-backend-tests--cairo-output
  (concat
   "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
   "<svg xmlns=\"http://www.w3.org/2000/svg\" "
   "xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
   "width=\"14pt\" height=\"12pt\" viewBox=\"0 0 14 12\">\n"
   "<defs>\n<g>\n<g id=\"glyph-0-0\">\n"
   "<path d=\"M 0 -4 L 3 -4 L 3 1 Z \"/>\n</g>\n</g>\n</defs>\n"
   "<g fill=\"rgb(0.390625%, 0.782776%, 1.174927%)\" fill-opacity=\"1\">\n"
   "<use xlink:href=\"#glyph-0-0\" x=\"5\" y=\"6\"/>\n</g>\n"
   "<g fill=\"rgb(0%, 0%, 0%)\" fill-opacity=\"1\">\n"
   "<use xlink:href=\"#glyph-0-0\" x=\"8\" y=\"6\"/>\n</g>\n</svg>\n")
  "What `pdftocairo -svg' writes, in short: a glyph in the marker ink
and one in a formula's own black.")

(ert-deftest latex-to-svg-backend-texres-cache-key-is-its-own ()
  ;; The texres engine reads the LaTeX engine's preamble, but its SVGs are
  ;; cached apart from LaTeX's and RaTeX's.
  (let ((doc "$x^2$"))
    (should-not (equal (latex-to-svg-backend--cache-key doc 'texres)
                       (latex-to-svg-backend--cache-key doc 'latex)))
    (should-not (equal (latex-to-svg-backend--cache-key doc 'texres)
                       (latex-to-svg-backend--cache-key doc 'ratex)))
    (let ((base (latex-to-svg-backend--cache-key doc 'texres))
          (latex-to-svg-backend-preamble-packages "\\usepackage{braket}"))
      (should-not (equal base (latex-to-svg-backend--cache-key doc 'texres))))
    (should (eq (latex-to-svg-backend--engine 'texres) 'texres))))

(ert-deftest latex-to-svg-backend-texres-compile-argv-and-store ()
  ;; texres runs as `pdflatex', through `-progname', with the marker ink
  ;; before the equation;
  ;; `pdftocairo -svg -noshrink' converts the PDF; the SVG is stored
  ;; cropped, with the marker as `currentColor' and the formula's own
  ;; black kept.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((latex-to-svg-backend-pdftocairo-program "pdftocairo-direct")
           (command (list "/bin/texres" "-progname=pdflatex"))
           (doc "$x^2$")
           (key (latex-to-svg-backend--cache-key doc 'texres))
           (callbacks 0))
      (cl-letf (((symbol-function 'latex-to-svg-backend--texres-command)
                 (lambda () command)))
        (latex-to-svg-backend--enqueue
         key doc (latex-to-svg-backend--waiter (lambda (_outcome) (cl-incf callbacks)))
         nil 'texres)
        (let* ((tex-process (car l2s-test-processes))
               (scratch (aref tex-process 4))
               (tex (expand-file-name "equation.tex" scratch))
               (pdf (expand-file-name "equation.pdf" scratch))
               (cairo (expand-file-name "cairo.svg" scratch)))
          (should (equal (plist-get (aref tex-process 3) :command)
                         (append command
                                 (list "-interaction=nonstopmode"
                                       "-halt-on-error" "equation.tex"))))
          (should (string-search
                   (concat "\\begin{document}\n"
                           latex-to-svg-backend--texres-wide-page
                           latex-to-svg-backend--texres-ink
                           doc "\n")
                   (latex-to-svg-backend-tests--tex-source tex)))
          (with-temp-file pdf (insert "fake pdf"))
          (latex-to-svg-backend-tests--finish-fake-process tex-process 0)
          (let ((cairo-process (car l2s-test-processes)))
            (should (equal (plist-get (aref cairo-process 3) :command)
                           (list "pdftocairo-direct" "-svg" "-noshrink"
                                 pdf cairo)))
            (with-temp-file cairo
              (insert latex-to-svg-backend-tests--cairo-output))
            (latex-to-svg-backend-tests--finish-fake-process cairo-process 0))
          (should (= callbacks 1))
          (should-not (gethash key latex-to-svg-backend--pending))
          (with-temp-buffer
            (insert-file-contents (latex-to-svg-backend--svg-file key))
            (should (search-forward
                     "width='6.0000pt' height='5.0000pt' viewBox='5.0000 2.0000"
                     nil t))
            (should (search-forward "fill=\"currentColor\"" nil t))
            (should (search-forward "fill=\"rgb(0%, 0%, 0%)\"" nil t))))))))

(ert-deftest latex-to-svg-backend-texres-store-recolors-black-without-marker ()
  ;; Without `xcolor' there is no marker, and no `\color' in a formula
  ;; either: black is the default ink and becomes `currentColor'.
  (let ((dir (make-temp-file "l2s-texres-store" t))
        (svg (make-temp-file "l2s-texres-store" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "cairo.svg" dir)
            (insert (replace-regexp-in-string
                     latex-to-svg-backend--texres-ink-svg "rgb(0%, 0%, 0%)"
                     latex-to-svg-backend-tests--cairo-output t t)))
          (should (latex-to-svg-backend--texres-store dir svg))
          (with-temp-buffer
            (insert-file-contents svg)
            (should-not (search-forward "rgb(0%" nil t))))
      (delete-directory dir t)
      (delete-file svg))))

(ert-deftest latex-to-svg-backend-texres-store-gives-the-baseline ()
  ;; The compile logs the baseline's height above the page bottom in sp,
  ;; and the page's height; pdftocairo puts the page top at y 0 and writes
  ;; big points.  A display equation logs nothing and gets no baseline.
  (let ((dir (make-temp-file "l2s-texres-store" t))
        (svg (make-temp-file "l2s-texres-store" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "cairo.svg" dir)
            (insert latex-to-svg-backend-tests--cairo-output))
          (with-temp-file (expand-file-name "equation.log" dir)
            (insert "(./equation.tex\n"
                    "latex-to-svg-backend-x-height 4.28932pt\n"
                    "latex-to-svg-backend-baseline 262145 14.0pt\n"
                    ")\n"))
          ;; (14pt - 4pt) * 72 / 72.27.
          (should (< (abs (- (latex-to-svg-backend--texres-baseline dir)
                             (* 10.0000153 (/ 72 72.27))))
                     1e-4))
          (should (latex-to-svg-backend--texres-store dir svg))
          (with-temp-buffer
            (insert-file-contents svg)
            (should (< (abs (- (latex-to-svg-backend--svg-baseline
                                (buffer-string))
                               9.9626))
                       1e-3))
            (should (equal (latex-to-svg-backend--svg-x-height (buffer-string))
                           4.28932)))
          (delete-file (expand-file-name "equation.log" dir))
          (should-not (latex-to-svg-backend--texres-baseline dir))
          (should (latex-to-svg-backend--texres-store dir svg))
          (with-temp-buffer
            (insert-file-contents svg)
            (should-not (latex-to-svg-backend--svg-baseline (buffer-string)))))
      (delete-directory dir t)
      (delete-file svg))))

(ert-deftest latex-to-svg-backend-texres-compile-end-to-end ()
  ;; End to end (needs texres and `pdftocairo'): inline, display and a
  ;; numbered environment render, cropped and color-independent.
  (skip-unless (latex-to-svg-backend-tools-available-p 'texres))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-texres-e2e" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (dolist (doc '("$x^2$"
                         "\\[\\int_0^1 f\\,dx\\]"
                         "\\begin{align}\na&=b \\\\\nc&=d\n\\end{align}"))
            (let ((done 'pending))
              (latex-to-svg-backend doc :engine 'texres
                                    :callback (lambda (outcome) (setq done (or outcome t))))
              (dotimes (_ 100)
                (when (eq done 'pending)
                  (accept-process-output nil 0.1)))
              (should (eq done t))
              (with-temp-buffer
                (insert-file-contents
                 (latex-to-svg-backend--svg-file
                  (latex-to-svg-backend--cache-key doc 'texres)))
                (should (search-forward "<svg xmlns='http://www.w3.org/2000/svg'" nil t))
                (should (search-forward "currentColor" nil t))
                (goto-char (point-min))
                (should-not (re-search-forward
                             latex-to-svg-backend--texres-ink-svg nil t))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-texres-keeps-a-wide-equation ()
  ;; End to end (needs LaTeX and texres): a display wider than the
  ;; `varwidth' box overflows it; texres's SVG is as wide as LaTeX's,
  ;; whose DVI has no page to cut it off.  Numbers on the left
  ;; (`leqno') and `flalign' overflow to the right too.
  (skip-unless (and (latex-to-svg-backend-tools-available-p 'latex)
                    (latex-to-svg-backend-tools-available-p 'texres)))
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-wide-e2e" t))
         (sum (mapconcat (lambda (i) (format "a_{%d}" i))
                         (number-sequence 1 40) " + "))
         (docs (mapcar (lambda (template) (format template sum))
                       '("\\[%s\\]"
                         "\\begin{equation}%s\\end{equation}"
                         "\\begin{align}x&=%s\\end{align}"
                         "\\begin{multline}%s\\end{multline}"
                         "\\begin{flalign}%s&&\\end{flalign}"
                         "\\begin{flalign}&&%s\\end{flalign}")))
         (base latex-to-svg-backend-preamble-base))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (dolist (leqno '(nil t))
            (let ((latex-to-svg-backend-preamble-base
                   (if leqno
                       (string-replace "border=2pt" "border=2pt,leqno" base)
                     base)))
              (dolist (doc docs)
                (let ((widths
                       (mapcar
                        (lambda (engine)
                          (let ((done 'pending))
                            (latex-to-svg-backend doc :engine engine
                                                  :callback (lambda (outcome)
                                                              (setq done (or outcome t))))
                            (dotimes (_ 100)
                              (when (eq done 'pending)
                                (accept-process-output nil 0.1)))
                            (should (eq done t))
                            (with-temp-buffer
                              (insert-file-contents
                               (latex-to-svg-backend--svg-file
                                (latex-to-svg-backend--cache-key doc engine)))
                              (string-to-number
                               (latex-to-svg-backend--svg-attribute
                                (buffer-substring (search-forward "<svg")
                                                  (search-forward ">"))
                                "width")))))
                        '(latex texres))))
                  (should (> (car widths) 400))
                  (should (< (abs (- (car widths) (cadr widths))) 1)))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;; Needs the programs of each engine it runs; an engine without them is
;; left out.
(ert-deftest latex-to-svg-backend-formula-error-end-to-end ()
  ;; The real log gives the message, the line in LATEX and the column:
  ;; `latex' prints the whole line, with the `.fmt' file loaded; texres
  ;; cuts a long line short.
  (let ((engines (seq-filter #'latex-to-svg-backend-tools-available-p
                             '(latex texres))))
    (skip-unless engines)
    (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-error-e2e" t))
          (latex-to-svg-backend-precompile t)
          (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
          (short "\\begin{equation}\nx = 1\n  + \\alsonot\n\\end{equation}")
          (long (concat "$a_{11} + a_{12} + a_{13} + a_{14} + a_{15} + a_{16} + "
                        "a_{17} + \\notacommand + b$")))
      (unwind-protect
          (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
                    ((symbol-function 'display-warning) #'ignore))
            (dolist (engine engines)
              (pcase-dolist (`(,doc ,line ,column)
                             `((,short 3 12)
                               (,long 1 ,(and (eq engine 'latex)
                                              (- (length long) (length " + b$"))))))
                (let ((done 'pending))
                  (latex-to-svg-backend doc :engine engine :quiet t
                                        :callback (lambda (outcome) (setq done outcome)))
                  (dotimes (_ 100)
                    (when (eq done 'pending)
                      (accept-process-output nil 0.1)))
                  (should (equal (seq-take done 10)
                                 (list :kind 'formula :engine engine
                                       :message "Undefined control sequence."
                                       :line line :column column)))))))
        (delete-directory latex-to-svg-backend-cache-directory t)))))

(ert-deftest latex-to-svg-backend-ratex-compile-end-to-end ()
  ;; End to end (needs RaTeX's `render-svg'): inline, display and a numbered
  ;; environment render, with a macro from `-ratex-macros'.
  (skip-unless (latex-to-svg-backend-tools-available-p 'ratex))
  (let ((latex-to-svg-backend-ratex-macros "\\newcommand{\\myvec}[1]{\\mathbf{#1}}")
        (latex-to-svg-backend-cache-directory (make-temp-file "l2s-ratex-e2e" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (dolist (doc '("$x^2 + \\myvec{v}$"
                         "\\[\\int_0^1 f\\,dx\\]"
                         "\\begin{align}\na&=b \\\\ % first\nc&=d\n\\end{align}"))
            (let ((done 'pending))
              (latex-to-svg-backend doc :engine 'ratex
                                    :callback (lambda (outcome) (setq done (or outcome t))))
              (dotimes (_ 100)
                (when (eq done 'pending)
                  (accept-process-output nil 0.1)))
              (should (eq done t))
              (with-temp-buffer
                (insert-file-contents
                 (latex-to-svg-backend--svg-file
                  (latex-to-svg-backend--cache-key doc 'ratex)))
                (should (search-forward "<svg xmlns='http://www.w3.org/2000/svg' width='" nil t))
                (should (search-forward "currentColor" nil t))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-baseline-end-to-end ()
  ;; End to end, for each engine whose programs are found: every SVG
  ;; gives its font's x-height, and an inline equation's its baseline, which puts most of `x' and about
  ;; two thirds of `y' above it; a display equation gives none and is
  ;; centred.
  (let ((engines (seq-filter #'latex-to-svg-backend-tools-available-p
                             '(latex ratex texres))))
    (skip-unless engines)
    (let ((latex-to-svg-backend-cache-directory
           (make-temp-file "l2s-baseline-e2e" t))
          (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
          (latex-to-svg-backend-ratex-macros ""))
      (unwind-protect
          (cl-letf (((symbol-function 'latex-to-svg-backend-available-p)
                     (lambda () t))
                    ((symbol-function 'display-warning)
                     (lambda (&rest w) (error "Unexpected warning: %S" w))))
            (dolist (engine engines)
              (dolist (doc '("$x$" "$y$" "\\[x=1\\]"))
                (let ((done 'pending))
                  (latex-to-svg-backend doc :engine engine
                                        :callback (lambda (outcome) (setq done (or outcome t))))
                  (dotimes (_ 200)
                    (when (eq done 'pending)
                      (accept-process-output nil 0.1)))
                  (should (eq done t))
                  (let* ((svg (with-temp-buffer
                                (insert-file-contents
                                 (latex-to-svg-backend--svg-file
                                  (latex-to-svg-backend--cache-key doc engine)))
                                (buffer-string)))
                         (ascent (latex-to-svg-backend--ascent svg)))
                    ;; Every SVG gives its font's x-height, displays too:
                    ;; Computer Modern's 4.30554pt in bp, or KaTeX's.
                    (should (< (abs (- (latex-to-svg-backend--svg-x-height svg)
                                       (if (eq engine 'ratex) 4.31 4.28932)))
                               1e-3))
                    (pcase doc
                      ("$x$" (should (<= 95 ascent 100)))
                      ("$y$" (should (<= 60 ascent 80)))
                      (_ (should (eq ascent 'center)))))))))
        (delete-directory latex-to-svg-backend-cache-directory t)))))

(ert-deftest latex-to-svg-backend-fallback-end-to-end ()
  ;; End to end (needs both engines): RaTeX has no `\sideset', LaTeX with
  ;; amsmath does.  The RaTeX failure is recorded, LaTeX draws the picture.
  (skip-unless (and (latex-to-svg-backend-tools-available-p 'latex)
                    (latex-to-svg-backend-tools-available-p 'ratex)))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fallback-e2e" t))
        (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
        (latex-to-svg-backend-ratex-macros "")
        (doc "$\\sideset{}{'}\\sum_{n} a_n$")
        (done 'pending))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
                  ((symbol-function 'display-warning)
                   (lambda (&rest w) (error "Unexpected warning: %S" w))))
          (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                                :callback (lambda (outcome) (setq done (or outcome t))))
          (dotimes (_ 200)
            (when (eq done 'pending)
              (accept-process-output nil 0.1)))
          (should (eq done t))
          (should (latex-to-svg-backend--failed-p
                   (latex-to-svg-backend--cache-key doc 'ratex)))
          (should (eq 'latex (latex-to-svg-backend-engine-used doc 'ratex 'latex))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Per-project preamble

(defmacro latex-to-svg-backend-tests--outside-a-project (&rest body)
  "Run BODY with `project-current' finding no project."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'project-current) #'ignore))
     ,@body))

(ert-deftest latex-to-svg-backend-empty-macros-leave-the-key ()
  ;; The option's default adds nothing, so every user's cache keeps its
  ;; keys, and the directory is not even looked up.
  (let ((latex-to-svg-backend-preamble-not-precompiled ""))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) (error "must not look for a project"))))
      (should (equal (latex-to-svg-backend--macros) ""))
      (should (equal (latex-to-svg-backend--latex-cache-salt (latex-to-svg-backend--latex-inputs))
                     (latex-to-svg-backend--preamble))))))

(ert-deftest latex-to-svg-backend-macros-search-the-project ()
  ;; `\input' searches the project root, else `default-directory'; the
  ;; directory is expanded, as `project-root' may return `~/...'.
  (let ((latex-to-svg-backend-preamble-not-precompiled "\\input{macros.tex}"))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) '(transient . "~/my proj_x"))))
      (should (equal (latex-to-svg-backend--macros)
                     (format "\\makeatletter\\def\\input@path{{%s}}\\makeatother
\\input{macros.tex}"
                             (expand-file-name "~/my proj_x/")))))
    (latex-to-svg-backend-tests--outside-a-project
      (let ((default-directory "/tmp/paper/"))
        (should (equal (latex-to-svg-backend--macros)
                       "\\makeatletter\\def\\input@path{{/tmp/paper/}}\\makeatother
\\input{macros.tex}"))))))

(ert-deftest latex-to-svg-backend-macros-fold-into-the-latex-key ()
  ;; The text and the directory are part of the LaTeX key, so two projects
  ;; with the same `\input{macros.tex}' do not share entries; the RaTeX
  ;; key ignores both.
  (latex-to-svg-backend-tests--outside-a-project
    (let* ((latex-to-svg-backend-ratex-macros "")
           (default-directory "/tmp/a/")
           (base (latex-to-svg-backend--cache-key "$x$"))
           (ratex (latex-to-svg-backend--cache-key "$x$" 'ratex))
           (latex-to-svg-backend-preamble-not-precompiled "\\input{macros.tex}")
           (a (latex-to-svg-backend--cache-key "$x$")))
      (should-not (equal a base))
      (should (equal ratex (latex-to-svg-backend--cache-key "$x$" 'ratex)))
      (let ((default-directory "/tmp/b/"))
        (should-not (equal a (latex-to-svg-backend--cache-key "$x$"))))
      ;; INPUTS passed in win over the current buffer's.
      (should (equal base (latex-to-svg-backend--cache-key
                           "$x$" 'latex
                           (list :preamble (latex-to-svg-backend--preamble)
                                 :macros "")))))))

(ert-deftest latex-to-svg-backend-input-directory-refuses-unusable-directories ()
  ;; A directory TeX would read as code, or one on another host, gets no
  ;; `\input@path' line; each refusal is reported once per buffer.
  (latex-to-svg-backend-tests--outside-a-project
    (with-temp-buffer
      (let ((latex-to-svg-backend-preamble-not-precompiled "\\input{macros.tex}")
            (warnings nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest w) (push w warnings))))
          (dolist (dir '("/tmp/50%/" "/tmp/a{b}/" "/tmp/x#1/" "/tmp/a~b/"
                         "/tmp/back\\slash/"))
            (let ((default-directory dir))
              (should (equal (latex-to-svg-backend--macros)
                             "\\input{macros.tex}"))))
          (should (= 1 (length warnings)))
          (let ((default-directory "/ssh:host:/home/me/paper/"))
            (should (equal (latex-to-svg-backend--macros)
                           "\\input{macros.tex}")))
          (should (= 2 (length warnings)))
          (should (string-match-p "remote" (nth 1 (car warnings))))
          (with-temp-buffer
            (let ((default-directory "/ssh:host:/home/me/paper/"))
              (latex-to-svg-backend--macros)))
          (should (= 3 (length warnings))))))))

(ert-deftest latex-to-svg-backend-compile-writes-the-macros-text ()
  ;; The macros text goes before `\begin{document}': after the `%&' line
  ;; with a `.fmt' file, after the preamble without.
  (latex-to-svg-backend-tests--with-fake-processes
    (latex-to-svg-backend-tests--outside-a-project
      (setq-local latex-to-svg-backend-preamble-not-precompiled "\\input{macros.tex}")
      (setq default-directory "/tmp/paper/")
      (let* ((doc "$\\RR$")
             (text (latex-to-svg-backend--macros))
             (key (latex-to-svg-backend--cache-key doc))
             (fmt (latex-to-svg-backend--format-file "fake-format"))
             (source (lambda ()
                       (latex-to-svg-backend-tests--tex-source
                        (latex-to-svg-backend-tests--tex-file
                         (car l2s-test-processes))))))
        (with-temp-file fmt (insert "fake format"))
        (puthash key (list (latex-to-svg-backend--waiter #'ignore))
                 latex-to-svg-backend--pending)
        (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                   (lambda (_preamble &optional _program _package-files) fmt))
                  ((symbol-function 'display-warning) #'ignore))
          (latex-to-svg-backend--compile key doc)
          (should (equal (funcall source)
                         (concat "%& " (file-name-sans-extension fmt) "\n"
                                 text "\n"
                                 "\\begin{document}\n" doc "\n"
                                 latex-to-svg-backend--latex-baseline-mark
                                 latex-to-svg-backend--latex-x-height-mark
                                 "\\end{document}\n")))
          (latex-to-svg-backend-tests--finish-fake-process
           (car l2s-test-processes) 0))
        (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                   #'ignore))
          (latex-to-svg-backend--compile key doc)
          (should (= 2 (length l2s-test-processes)))
          (should (equal (funcall source)
                         (concat (latex-to-svg-backend--preamble) "\n"
                                 text "\n"
                                 "\\begin{document}\n" doc "\n"
                                 latex-to-svg-backend--latex-baseline-mark
                                 latex-to-svg-backend--latex-x-height-mark
                                 "\\end{document}\n"))))))))

(ert-deftest latex-to-svg-backend-fallback-uses-the-requesting-buffer ()
  ;; RaTeX ignores the macros text; the LaTeX fallback, started from
  ;; the sentinel in another buffer, compiles with the requesting
  ;; buffer's, under the key that buffer computes.
  (latex-to-svg-backend-tests--with-public-api
    (latex-to-svg-backend-tests--outside-a-project
      (setq-local latex-to-svg-backend-preamble-not-precompiled "\\input{macros.tex}")
      (setq default-directory "/tmp/paper/")
      (let* ((doc "$\\RR$")
             (text (latex-to-svg-backend--macros))
             (latex-key (latex-to-svg-backend--cache-key doc 'latex))
             (callbacks 0))
        (cl-letf (((symbol-function 'run-with-timer) #'ignore))
          (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                                :x-height 10 :color "#000000"
                                :callback (lambda (_outcome) (cl-incf callbacks)))
          (with-temp-buffer
            (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes)))
          (let ((latex (car l2s-test-processes)))
            (should (string-search
                     (concat text "\n\\begin{document}")
                     (latex-to-svg-backend-tests--tex-source
                      (latex-to-svg-backend-tests--tex-file latex))))
            (with-temp-buffer
              (latex-to-svg-backend-tests--succeed-latex
               latex (lambda () (car l2s-test-processes)))))
          (should (= callbacks 1))
          (should (file-exists-p (latex-to-svg-backend--svg-file latex-key)))
          (should (eq 'image (latex-to-svg-backend
                              doc :engine 'ratex :fallback 'latex
                              :x-height 10 :color "#000000"
                              :callback #'ignore))))))))

(ert-deftest latex-to-svg-backend-macros-end-to-end ()
  ;; End to end (needs latex + dvisvgm): project macros `\input' from a
  ;; directory with a space and an underscore in its name, one file below
  ;; it, with the precompiled preamble and without.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-local-e2e" t))
         (project (file-name-as-directory
                   (expand-file-name "my proj_x" latex-to-svg-backend-cache-directory)))
         (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal)))
    (unwind-protect
        (with-temp-buffer
          (make-directory (expand-file-name "sub" project) t)
          (with-temp-file (expand-file-name "macros.tex" project)
            (insert "\\newcommand{\\RR}{\\mathbb{R}}\n"))
          (with-temp-file (expand-file-name "sub/more.tex" project)
            (insert "\\newcommand{\\QQ}{\\mathbb{Q}}\n"))
          (setq default-directory project)
          (setq-local latex-to-svg-backend-preamble-not-precompiled
                      "\\input{macros.tex}\n\\input{sub/more.tex}")
          (cl-letf (((symbol-function 'project-current) #'ignore)
                    ((symbol-function 'latex-to-svg-backend-available-p)
                     (lambda () t)))
            (dolist (precompile '(t nil))
              (let ((latex-to-svg-backend-precompile precompile)
                    (done 'pending)
                    (doc (format "$\\RR \\QQ %s$" precompile)))
                (latex-to-svg-backend doc :callback (lambda (outcome) (setq done (or outcome t))))
                (dotimes (_ 200)
                  (when (eq done 'pending) (accept-process-output nil 0.1)))
                (should (eq done t))
                (should (file-exists-p
                         (latex-to-svg-backend--svg-file
                          (latex-to-svg-backend--cache-key doc))))))
            ;; The `.fmt' file holds the global preamble only.
            (should (file-exists-p
                     (latex-to-svg-backend--format-file
                      (latex-to-svg-backend--format-key (latex-to-svg-backend--preamble)))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Buffer-local options

(ert-deftest latex-to-svg-backend-preamble-files-fold-into-the-key ()
  ;; A listed file's modification time is in the key, so an edit of it
  ;; compiles the equation again; nothing listed leaves the key as it was.
  ;; A name is relative to the directory `\input' searches.
  (latex-to-svg-backend-tests--outside-a-project
    (with-temp-buffer
      (let* ((dir (file-name-as-directory (make-temp-file "l2s-files" t)))
             (macros (expand-file-name "macros.tex" dir))
             (sty (expand-file-name "mine.sty" dir))
             (key (lambda ()
                    (latex-to-svg-backend--cache-key
                     "$x$" 'latex (latex-to-svg-backend--inputs)))))
        (unwind-protect
            (progn
              (setq default-directory dir)
              (with-temp-file macros (insert "\\def\\a{a}"))
              (with-temp-file sty (insert "\\def\\b{b}"))
              (set-file-times macros '(1 0))
              (set-file-times sty '(1 0))
              (let ((bare (funcall key)))
                (setq-local latex-to-svg-backend-preamble-not-precompiled-files
                            '("macros.tex"))
                (let ((files (plist-get (latex-to-svg-backend--inputs)
                                        :macro-files)))
                  (should (equal (mapcar #'car files) (list macros)))
                  (should (time-equal-p (cdar files) '(1 0))))
                (let ((listed (funcall key)))
                  (should-not (equal bare listed))
                  (set-file-times macros '(2 0))
                  (should-not (equal listed (funcall key))))
                (let ((before (funcall key)))
                  (setq-local latex-to-svg-backend-preamble-package-files
                              (list sty))
                  (should-not (equal before (funcall key))))
                (kill-local-variable 'latex-to-svg-backend-preamble-not-precompiled-files)
                (kill-local-variable 'latex-to-svg-backend-preamble-package-files)
                (should (equal bare (funcall key)))))
          (delete-directory dir t))))))

(ert-deftest latex-to-svg-backend-missing-preamble-file-warns-once ()
  ;; A listed file that does not exist is warned about once per buffer,
  ;; and stamped with no modification time.
  (latex-to-svg-backend-tests--outside-a-project
    (with-temp-buffer
      (let ((default-directory "/tmp/l2s-no-such-project/")
            (warnings nil))
        (setq-local latex-to-svg-backend-preamble-not-precompiled-files '("macros.tex"))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest w) (push w warnings))))
          (dotimes (_ 2)
            (should (equal (plist-get (latex-to-svg-backend--inputs)
                                      :macro-files)
                           '(("/tmp/l2s-no-such-project/macros.tex"))))))
        (should (= 1 (length warnings)))
        (should (string-match-p "latex-to-svg-backend-preamble-not-precompiled-files"
                                (nth 1 (car warnings))))))))

(ert-deftest latex-to-svg-backend-package-files-make-the-format-stale ()
  ;; The stamp records the package files: an edit of one, or another
  ;; list, makes the `.fmt' file stale.  Macro files are not in it.
  (let* ((binary (make-temp-file "l2s-bin"))
         (sty (make-temp-file "l2s-sty"))
         (files (list (latex-to-svg-backend--preamble-file-stamp sty)))
         (stamp (latex-to-svg-backend--format-stamp binary nil files)))
    (unwind-protect
        (progn
          (should (equal (plist-get stamp :preamble-package-files) files))
          (should (latex-to-svg-backend--format-fresh-p stamp binary files))
          (should-not (latex-to-svg-backend--format-fresh-p stamp binary))
          (set-file-times sty '(5 0))
          (should-not (latex-to-svg-backend--format-fresh-p
                       stamp binary
                       (list (latex-to-svg-backend--preamble-file-stamp sty))))
          (let ((none (latex-to-svg-backend--format-stamp binary)))
            (should-not (plist-member none :preamble-package-files))
            (should (latex-to-svg-backend--format-fresh-p none binary))))
      (delete-file binary)
      (delete-file sty))))

(ert-deftest latex-to-svg-backend-compile-checks-the-package-files ()
  ;; The compile hands the request's package files to the `.fmt' check,
  ;; and not its macro files.
  (latex-to-svg-backend-tests--with-fake-processes
    (latex-to-svg-backend-tests--outside-a-project
      (let (seen)
        (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                   (lambda (_preamble &optional _program package-files)
                     (setq seen package-files)
                     nil)))
          (latex-to-svg-backend--compile
           (latex-to-svg-backend--cache-key "$x$") "$x$" nil
           (list :preamble (latex-to-svg-backend--preamble) :macros ""
                 :package-files '(("/p/mine.sty" 1 . 1))
                 :macro-files '(("/p/macros.tex" 2 . 1))))
          (should (equal seen '(("/p/mine.sty" 1 . 1)))))))))

(ert-deftest latex-to-svg-backend-old-preamble-names-still-work ()
  ;; The names before 0.16.0, and `-preamble' before 0.17.0, are obsolete
  ;; aliases: a `.dir-locals.el' that sets one sets the new option in the
  ;; buffer.
  (latex-to-svg-backend-tests--outside-a-project
    (with-temp-buffer
      (setq default-directory "/tmp/a/")
      (set (make-local-variable 'latex-to-svg-backend-preamble)
           "\\documentclass{standalone}")
      (should (local-variable-p 'latex-to-svg-backend-preamble-base))
      (should (equal latex-to-svg-backend-preamble-base
                     "\\documentclass{standalone}"))
      (should (string-prefix-p
               "\\makeatletter\\def\\input@path{{/tmp/a/}}\\makeatother\n"
               (latex-to-svg-backend--preamble)))))
  (with-temp-buffer
    (set (make-local-variable 'latex-to-svg-backend-appended-preamble)
         "\\usepackage{physics}")
    (set (make-local-variable 'latex-to-svg-backend-preamble-macros)
         "\\def\\a{a}")
    (set (make-local-variable 'latex-to-svg-backend-preamble-macro-files)
         '("macros.tex"))
    (should (local-variable-p 'latex-to-svg-backend-preamble-packages))
    (should (equal latex-to-svg-backend-preamble-packages
                   "\\usepackage{physics}"))
    (should (equal latex-to-svg-backend-preamble-not-precompiled "\\def\\a{a}"))
    (should (equal latex-to-svg-backend-preamble-not-precompiled-files
                   '("macros.tex"))))
  (should (equal latex-to-svg-backend-preamble-packages "")))

(ert-deftest latex-to-svg-backend-warns-of-an-obsolete-alias ()
  ;; An alias set before the backend loaded is reported with what
  ;; `make-obsolete-variable' recorded.  The check at load runs only when
  ;; the file loads; this tests the warning.
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _)
                 (push message warnings))))
      (latex-to-svg-backend--warn-obsolete-alias
       'latex-to-svg-backend-preamble)
      (latex-to-svg-backend--warn-obsolete-alias
       'latex-to-svg-backend-appended-preamble)
      (latex-to-svg-backend--warn-obsolete-alias
       'latex-to-svg-backend-preamble-macros)
      (latex-to-svg-backend--warn-obsolete-alias
       'latex-to-svg-backend-preamble-macro-files))
    (should (equal (reverse warnings)
                   '("`latex-to-svg-backend-preamble' is obsolete since \
0.17.0; use `latex-to-svg-backend-preamble-base' instead."
                     "`latex-to-svg-backend-appended-preamble' is obsolete \
since 0.16.0; use `latex-to-svg-backend-preamble-packages' instead."
                     "`latex-to-svg-backend-preamble-macros' is obsolete \
since 0.18.0; put macro files in `latex-to-svg-backend-preamble-packages' \
and list them in `latex-to-svg-backend-preamble-package-files'."
                     "`latex-to-svg-backend-preamble-macro-files' is \
obsolete since 0.18.0; use \
`latex-to-svg-backend-preamble-not-precompiled-files' instead.")))))

(ert-deftest latex-to-svg-backend-buffer-local-preamble-searches-the-project ()
  ;; A buffer-local `-preamble-base' or `-preamble-packages' starts the preamble
  ;; with the `\input@path' line, so the dump, which runs in the cache,
  ;; finds a relative `\input'; the directory is then part of the `.fmt'
  ;; key.  A global value writes no such line and shares one `.fmt' file.
  (latex-to-svg-backend-tests--outside-a-project
    (with-temp-buffer
      (let ((default-directory "/tmp/a/")
            (global (latex-to-svg-backend--preamble)))
        (should-not (string-search "input@path" global))
        (setq-local latex-to-svg-backend-preamble-packages "\\input{macros.tex}")
        (let ((a (latex-to-svg-backend--preamble)))
          (should (string-prefix-p
                   "\\makeatletter\\def\\input@path{{/tmp/a/}}\\makeatother\n" a))
          (should (string-suffix-p "\n\\input{macros.tex}" a))
          (let ((default-directory "/tmp/b/"))
            (should-not (equal (latex-to-svg-backend--format-key a)
                               (latex-to-svg-backend--format-key
                                (latex-to-svg-backend--preamble))))))
        (kill-local-variable 'latex-to-svg-backend-preamble-packages)
        (setq-local latex-to-svg-backend-preamble-base "\\documentclass{standalone}")
        (should (string-search "input@path" (latex-to-svg-backend--preamble)))
        (kill-local-variable 'latex-to-svg-backend-preamble-base)
        (let ((default-directory "/tmp/b/"))
          (should (equal global (latex-to-svg-backend--preamble))))))))

(ert-deftest latex-to-svg-backend-dump-uses-the-requesting-buffer ()
  ;; The dump writes the requesting buffer's preamble, also when it runs
  ;; in another buffer: it dumps the preamble it is given.
  (latex-to-svg-backend-tests--outside-a-project
    (with-temp-buffer
      (setq-local latex-to-svg-backend-preamble-packages "\\usepackage{physics}")
      (setq default-directory "/tmp/paper/")
      (let ((preamble (latex-to-svg-backend--preamble))
            (latex-to-svg-backend-cache-directory (make-temp-file "l2s-dump" t))
            (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
            dumped)
        (unwind-protect
            (progn
              (should (string-search "physics" preamble))
              (cl-letf (((symbol-function 'call-process)
                         (lambda (&rest args)
                           (setq dumped (latex-to-svg-backend-tests--tex-source
                                         (car (last args))))
                           1))
                        ((symbol-function 'display-warning) #'ignore))
                (with-temp-buffer
                  (let ((latex-to-svg-backend-precompile t))
                    (latex-to-svg-backend--ensure-format preamble)))
                (should (equal dumped (concat preamble "\n\\dump\n")))))
          (delete-directory latex-to-svg-backend-cache-directory t))))))

(ert-deftest latex-to-svg-backend-fallback-to-ratex-uses-the-requesting-buffer ()
  ;; A LaTeX-to-RaTeX fallback starts from the sentinel, in another buffer,
  ;; and still renders with the requesting buffer's RaTeX macros.
  (latex-to-svg-backend-tests--with-public-api
    (setq-local latex-to-svg-backend-ratex-macros "\\def\\vv{\\mathbf{v}}")
    (let ((doc "$\\vv$"))
      (latex-to-svg-backend doc :engine 'latex :fallback 'ratex
                            :x-height 10 :color "#000000" :callback #'ignore)
      (let ((latex (car l2s-test-processes)))
        (with-temp-file (expand-file-name "equation.log" (aref latex 4))
          (insert "! Undefined control sequence.\n"))
        (with-temp-buffer
          (latex-to-svg-backend-tests--finish-fake-process latex 1)))
      (let* ((plist (aref (car l2s-test-processes) 3))
             (command (plist-get plist :command)))
        (should (equal (car command) "ratex-direct"))
        (should (string-prefix-p "\\def\\vv{\\mathbf{v}}"
                                 (with-temp-buffer
                                   (insert-file-contents (nth 2 command))
                                   (buffer-string))))
        ;; The output buffer is named after the key the SVG is stored under.
        (should (string-search (latex-to-svg-backend--cache-key doc 'ratex)
                               (buffer-name (plist-get plist :buffer))))))))

(defmacro latex-to-svg-backend-tests--with-format-cache (&rest body)
  "Run BODY with an empty cache, precompilation on, and a fake LaTeX binary.
The binary is bound to `binary'; the dump is stubbed to write the
`.fmt' and its stamp, and counts itself in `builds'."
  (declare (indent 0) (debug t))
  `(let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-stamp" t))
          (latex-to-svg-backend-precompile t)
          (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
          (binary (make-temp-file "l2s-bin"))
          (builds 0))
     (unwind-protect
         (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                    (lambda (&optional _program) binary))
                   ((symbol-function 'latex-to-svg-backend--build-format)
                    (lambda (fkey _preamble &optional _program _package-files)
                      (cl-incf builds)
                      (let ((f (latex-to-svg-backend--format-file fkey)))
                        (with-temp-file f (insert "fmt"))
                        (latex-to-svg-backend--write-format-stamp f binary)
                        f))))
           ,@body)
       (delete-file binary)
       (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-format-drops-the-buffers-fmt ()
  ;; The buffer's `.fmt' file goes, with its stamp and its freshness
  ;; check; other preambles' `.fmt' files stay.
  (latex-to-svg-backend-tests--with-format-cache
    (latex-to-svg-backend-tests--outside-a-project
      (let* ((fmt (latex-to-svg-backend--ensure-format
                   (latex-to-svg-backend--preamble)))
             (fkey (file-name-base fmt))
             (other (latex-to-svg-backend--format-file "other")))
        (with-temp-file other (insert "fmt"))
        (latex-to-svg-backend--write-format-stamp other binary)
        (latex-to-svg-backend-invalidate-format)
        (should-not (file-exists-p fmt))
        (should-not (file-exists-p (latex-to-svg-backend--format-stamp-file fmt)))
        (should-not (gethash fkey latex-to-svg-backend--format-stamps))
        (should (file-exists-p other))
        (should (file-exists-p (latex-to-svg-backend--format-stamp-file other)))
        ;; The next compile dumps it again.
        (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))
        (should (= builds 2))))))

(ert-deftest latex-to-svg-backend-buffer-local-preamble-end-to-end ()
  ;; End to end (needs latex + dvisvgm): a buffer-local
  ;; `-preamble-packages' with a relative `\input' is dumped into the
  ;; buffer's own `.fmt' file, and its macros typeset.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-append-e2e" t))
         (project (file-name-as-directory
                   (expand-file-name "my proj_x" latex-to-svg-backend-cache-directory)))
         (latex-to-svg-backend-precompile t)
         (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal)))
    (unwind-protect
        (with-temp-buffer
          (make-directory project t)
          (with-temp-file (expand-file-name "macros.tex" project)
            (insert "\\newcommand{\\RR}{\\mathbb{R}}\n"))
          (setq default-directory project)
          (setq-local latex-to-svg-backend-preamble-packages "\\input{macros.tex}")
          (cl-letf (((symbol-function 'project-current) #'ignore)
                    ((symbol-function 'latex-to-svg-backend-available-p)
                     (lambda () t)))
            (let ((done 'pending)
                  (doc "$\\RR$"))
              (latex-to-svg-backend doc :callback (lambda (outcome) (setq done (or outcome t))))
              (dotimes (_ 200)
                (when (eq done 'pending) (accept-process-output nil 0.1)))
              (should (eq done t))
              (should (file-exists-p
                       (latex-to-svg-backend--svg-file
                        (latex-to-svg-backend--cache-key doc))))
              (should (file-exists-p
                       (latex-to-svg-backend--format-file
                        (latex-to-svg-backend--format-key
                         (latex-to-svg-backend--preamble))))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Stamps and collection of the `.fmt' files

(ert-deftest latex-to-svg-backend-format-stamp-decides-freshness ()
  ;; A `.fmt' file is reused while its stamp names the binary and its
  ;; mtime; another binary, a changed mtime, a stamp from before 0.16.0
  ;; or no stamp dumps it again, in the same session too.  The mtime of
  ;; the `.fmt' file plays no part.
  (latex-to-svg-backend-tests--with-format-cache
    (let* ((fmt (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble)))
           (stamp (latex-to-svg-backend--format-stamp-file fmt))
           (again (lambda ()
                    (latex-to-svg-backend--ensure-format
                     (latex-to-svg-backend--preamble))))
           (new-session (lambda ()
                          (clrhash latex-to-svg-backend--format-stamps)
                          (funcall again))))
      (should (= builds 1))
      (should (equal (with-temp-buffer (insert-file-contents stamp)
                                       (read (current-buffer)))
                     (list :binary
                           (latex-to-svg-backend--file-stamp binary))))
      ;; A `.fmt' file older than the binary is still the binary's.
      (set-file-times fmt '(1 0))
      (should (equal fmt (funcall new-session)))
      (should (= builds 1))
      ;; The same binary, rebuilt, during the session.
      (set-file-times binary '(2 0))
      (should (equal fmt (funcall again)))
      (should (= builds 2))
      ;; Another binary.
      (let ((binary (make-temp-file "l2s-other-bin")))
        (unwind-protect
            (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                       (lambda (&optional _program) binary)))
              (funcall again)
              (should (= builds 3)))
          (delete-file binary)))
      ;; A stamp from before 0.16.0.
      (with-temp-file stamp
        (prin1 (list :binary binary
                     :mtime (file-attribute-modification-time
                             (file-attributes binary)))
               (current-buffer)))
      (funcall new-session)
      (should (= builds 4))
      ;; A `.fmt' file dumped before stamps existed.
      (delete-file stamp)
      (funcall new-session)
      (should (= builds 5)))))

(ert-deftest latex-to-svg-backend-format-stamp-follows-the-distribution ()
  ;; The dump's `-recorder' list names the distribution's `.fmt' file and
  ;; the files of a TeX tree: the stamp records that `.fmt' file and the
  ;; tree's `ls-R', and a change of either makes the `.fmt' file stale.
  ;; The `ls-R' is a link into `/var', as on Debian.  A file in no tree
  ;; adds nothing.
  (let* ((root (file-name-as-directory (make-temp-file "l2s-tree" t)))
         (binary (make-temp-file "l2s-bin"))
         (base (expand-file-name "texmf-var/web2c/pdftex/latex.fmt" root))
         (sty (expand-file-name "texmf-dist/tex/latex/amsmath/amsmath.sty" root))
         (link (expand-file-name "texmf-dist/ls-R" root))
         (index (expand-file-name "var/ls-R-TEXLIVEDIST" root))
         (outside (make-temp-file "l2s-macros"))
         (fls (expand-file-name "dump.fls" root)))
    (unwind-protect
        (progn
          (dolist (file (list base sty index))
            (make-directory (file-name-directory file) t)
            (with-temp-file file (insert "x")))
          (make-symbolic-link index link)
          (with-temp-file fls
            (insert (format "PWD %s\nINPUT %s\nINPUT %s\nINPUT %s\nINPUT dump.tex\n\
OUTPUT dump.fmt\n" root base sty outside)))
          (let* ((inputs (latex-to-svg-backend--recorded-inputs fls))
                 (stamp (latex-to-svg-backend--format-stamp binary inputs)))
            (should (equal inputs (list base sty outside)))
            (should (equal (car (plist-get stamp :latex-fmt)) base))
            (should (equal (mapcar #'car (plist-get stamp :ls-r))
                           (list index)))
            (should (latex-to-svg-backend--format-fresh-p stamp binary))
            (set-file-times index '(3 0))
            (should-not (latex-to-svg-backend--format-fresh-p stamp binary))
            (setq stamp (latex-to-svg-backend--format-stamp binary inputs))
            (set-file-times base '(3 0))
            (should-not (latex-to-svg-backend--format-fresh-p stamp binary))
            (setq stamp (latex-to-svg-backend--format-stamp binary inputs))
            (delete-file base)
            (should-not (latex-to-svg-backend--format-fresh-p stamp binary))))
      (delete-file binary)
      (delete-file outside)
      (delete-directory root t))))

(ert-deftest latex-to-svg-backend-unreadable-format-stamp-dumps-again ()
  ;; A truncated stamp is treated as stale, with no warning: the dump
  ;; writes a new one.
  (latex-to-svg-backend-tests--with-format-cache
    (let ((warnings 0)
          (fmt (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))))
      (with-temp-file (latex-to-svg-backend--format-stamp-file fmt)
        (insert "(:binary \"/x"))
      (clrhash latex-to-svg-backend--format-stamps)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest _) (cl-incf warnings))))
        (should (equal fmt (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble)))))
      (should (= builds 2))
      (should (= warnings 0)))))

(ert-deftest latex-to-svg-backend-build-format-writes-the-stamp ()
  ;; The dump runs `latex -ini' on the preamble followed by TeX's `\dump',
  ;; and a successful one writes the stamp next to the `.fmt'.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-dump" t))
         (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
         (binary (make-temp-file "l2s-bin"))
         (inhibit-message t)
         argv source)
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                   (lambda (&optional _program) binary))
                  ((symbol-function 'call-process)
                   (lambda (_program _infile _buffer _display &rest args)
                     (setq argv args
                           source (latex-to-svg-backend-tests--tex-source
                                   (car (last args))))
                     (with-temp-file (latex-to-svg-backend--format-file "abc")
                       (insert "fmt"))
                     (with-temp-file (expand-file-name
                                      "abc.fls" (latex-to-svg-backend--fmt-dir))
                       (insert "INPUT /no/such/latex.fmt\n"))
                     0)))
          (let ((fmt (latex-to-svg-backend--build-format "abc" (latex-to-svg-backend--preamble))))
            (should (equal (cdr argv)
                           (list "-ini" "-recorder" "-jobname=abc" "&latex"
                                 (expand-file-name
                                  "abc.tex" (latex-to-svg-backend--fmt-dir)))))
            (should (equal source (concat (latex-to-svg-backend--preamble)
                                          "\n\\dump\n")))
            (should (equal fmt (latex-to-svg-backend--format-file "abc")))
            (should (latex-to-svg-backend--format-fresh-p
                     (latex-to-svg-backend--read-format-stamp fmt) binary))
            (should (equal (gethash "abc" latex-to-svg-backend--format-stamps)
                           (latex-to-svg-backend--read-format-stamp fmt)))
            (should-not (file-exists-p
                         (expand-file-name "abc.fls" (latex-to-svg-backend--fmt-dir))))))
      (delete-file binary)
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-build-format-passes-the-arguments ()
  ;; A TeX program with arguments dumps with them first, from the `.fmt'
  ;; file its `-progname' names.
  (let* ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-dump" t))
         (latex-to-svg-backend--format-stamps (make-hash-table :test 'equal))
         (inhibit-message t)
         program argv)
    (unwind-protect
        (cl-letf (((symbol-function 'call-process)
                   (lambda (prog _infile _buffer _display &rest args)
                     (setq program prog argv args)
                     1))
                  ((symbol-function 'display-warning) #'ignore))
          (should (eq 'failed
                      (car (latex-to-svg-backend--build-format
                            "abc" "\\documentclass{article}"
                            '("/a/texres" "-progname=pdflatex")))))
          (should (equal program "/a/texres"))
          (should (equal (car argv) "-progname=pdflatex"))
          (should (member "&pdflatex" argv)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-format-use-bumps-its-mtime ()
  ;; Each compile that loads a `.fmt' file bumps its mtime, the GC's last-use
  ;; hint, also after the session has verified it.
  (latex-to-svg-backend-tests--with-format-cache
    (let* ((fmt (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble)))
           (age (lambda ()
                  (- (float-time)
                     (float-time (file-attribute-modification-time
                                  (file-attributes fmt)))))))
      (dolist (session '(new same))
        (when (eq session 'new)
          (clrhash latex-to-svg-backend--format-stamps))
        (set-file-times fmt '(1 0))
        (should (equal fmt (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))))
        (should (< (funcall age) 60)))
      (should (= builds 1)))))

(ert-deftest latex-to-svg-backend-collected-format-means-a-full-compile ()
  ;; A `.fmt' file another session collected between the check and the touch
  ;; gives nil: the compile embeds the full preamble.
  (latex-to-svg-backend-tests--with-format-cache
    (let ((fmt (latex-to-svg-backend--ensure-format (latex-to-svg-backend--preamble))))
      (cl-letf (((symbol-function 'set-file-times)
                 (lambda (file &rest _)
                   (signal 'file-missing (list "Setting file times" file)))))
        (should-not (latex-to-svg-backend--touch-format fmt))))))

(ert-deftest latex-to-svg-backend-invalidate-and-flush-delete-failed-stamps ()
  ;; A failed dump leaves a stamp and no `.fmt' file.  Invalidating the
  ;; buffer's `.fmt' file deletes the stamp, so the next compile dumps
  ;; again; a flush deletes every stamp.
  (latex-to-svg-backend-tests--with-format-cache
    (latex-to-svg-backend-tests--outside-a-project
      (let* ((preamble (latex-to-svg-backend--preamble))
             (fmt (latex-to-svg-backend--format-file
                   (latex-to-svg-backend--format-key preamble)))
             (stamp (latex-to-svg-backend--format-stamp-file fmt))
             (log (concat (file-name-sans-extension fmt) ".log"))
             (other (latex-to-svg-backend--format-file "other")))
        (latex-to-svg-backend--write-format-stamp fmt binary nil nil t)
        (should (equal (latex-to-svg-backend--ensure-format preamble)
                       (cons 'failed log)))
        (should (= builds 0))
        (latex-to-svg-backend-invalidate-format)
        (should-not (file-exists-p stamp))
        (should (equal (latex-to-svg-backend--ensure-format preamble) fmt))
        (should (= builds 1))
        (latex-to-svg-backend--write-format-stamp other binary nil nil t)
        (latex-to-svg-backend-flush-format)
        (should-not (directory-files (latex-to-svg-backend--fmt-dir)
                                     nil "\\.\\(?:fmt\\|eld\\)\\'"))))))
(ert-deftest latex-to-svg-backend-gc-collects-old-formats ()
  ;; A `.fmt' file untouched for longer than the age cap goes with its
  ;; stamp; a failed dump's stamp and log go, dated by the stamp; a
  ;; `.fmt' file in use stays.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-fmt" t))
        (latex-to-svg-backend-cache-max-age 30)
        (old (* 90 86400)))
    (unwind-protect
        (let* ((dir (latex-to-svg-backend--fmt-dir))
               (file (lambda (name age)
                       (let ((f (expand-file-name name dir)))
                         (with-temp-file f (insert "12345"))
                         (set-file-times f (seconds-to-time (- (float-time) age)))
                         f)))
               (old-fmt (funcall file "old.fmt" old))
               ;; The stamp is written with the dump, and not touched since.
               (old-eld (funcall file "old.eld" old))
               (new-fmt (funcall file "new.fmt" 0))
               (new-eld (funcall file "new.eld" old))
               (failed-eld (funcall file "failed.eld" old))
               (failed-log (funcall file "failed.log" old)))
          (should (equal (latex-to-svg-backend-gc) '(2 . 20)))
          (should-not (file-exists-p old-fmt))
          (should-not (file-exists-p old-eld))
          (should-not (file-exists-p failed-eld))
          (should-not (file-exists-p failed-log))
          (should (file-exists-p new-fmt))
          (should (file-exists-p new-eld)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Cancelling a request

(ert-deftest latex-to-svg-backend-cancel-takes-a-queued-compile-off-the-queue ()
  ;; With one slot, the second equation waits; cancelling its request
  ;; takes it off the queue, so the slot stays free when the first ends.
  (latex-to-svg-backend-tests--with-public-api
    (let ((latex-to-svg-backend-jobs 1)
          (called nil)
          (cancelled (lambda (_outcome) (error "Cancelled callback called"))))
      (latex-to-svg-backend "$a$" :engine 'ratex
                            :callback (lambda (_outcome) (setq called t)))
      (latex-to-svg-backend "$b$" :engine 'ratex :callback cancelled)
      (should (= (length l2s-test-processes) 1))
      (should (latex-to-svg-backend-cancel cancelled))
      (should-not latex-to-svg-backend--queue)
      (should-not (gethash (latex-to-svg-backend--cache-key "$b$" 'ratex)
                           latex-to-svg-backend--pending))
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (latex-to-svg-backend-tests--run-timers)
      (should called)
      (should (= (length l2s-test-processes) 1))
      (should-not latex-to-svg-backend--running))))

(ert-deftest latex-to-svg-backend-cancel-stops-a-running-compile ()
  ;; The `latex' process is killed and its scratch directory deleted, the
  ;; slot starts the queued compile, and nothing is recorded: not a
  ;; failure, and not the `.fmt' file the compile loaded.  The same
  ;; equation requested again compiles again.
  (latex-to-svg-backend-tests--with-public-api
    (let* ((latex-to-svg-backend-jobs 1)
           (fmt (expand-file-name "fake.fmt" l2s-test-cache-dir))
           (key (latex-to-svg-backend--cache-key "$a$"))
           (cancelled (lambda (_outcome) (error "Cancelled callback called"))))
      (with-temp-file fmt (insert "fake format"))
      (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                 (lambda (_preamble &optional _program _package-files) fmt)))
        (latex-to-svg-backend "$a$" :callback cancelled)
        (latex-to-svg-backend "$b$" :callback #'ignore)
        (let* ((process (car l2s-test-processes))
               (scratch (aref process 4))
               (buffer (plist-get (aref process 3) :buffer)))
          (should (equal (file-name-directory (directory-file-name scratch))
                         (file-name-as-directory
                          (expand-file-name "tmp" l2s-test-cache-dir))))
          (latex-to-svg-backend-cancel cancelled)
          (should (eq (aref process 1) 'signal))
          (should-not (file-directory-p scratch))
          (should-not (buffer-live-p buffer))
          (should (= (length l2s-test-processes) 2))
          (should (equal latex-to-svg-backend--running
                         (list (latex-to-svg-backend--cache-key "$b$"))))
          (should-not (gethash key latex-to-svg-backend--processes))
          (should-not (file-exists-p (latex-to-svg-backend--meta-file key)))
          (should-not (file-exists-p (latex-to-svg-backend--log-file key)))
          (should (file-exists-p fmt))
          (should-not l2s-test-warnings)
          (latex-to-svg-backend-tests--run-timers)
          (latex-to-svg-backend "$a$" :callback #'ignore)
          (should (equal (mapcar #'car latex-to-svg-backend--queue)
                         (list key))))))))

(ert-deftest latex-to-svg-backend-cancel-keeps-a-compile-another-request-waits-for ()
  ;; Two requests share one compile: cancelling one leaves the compile
  ;; running for the other, whose callback alone is called.
  (latex-to-svg-backend-tests--with-public-api
    (let ((called nil)
          (cancelled (lambda (_outcome) (error "Cancelled callback called"))))
      (latex-to-svg-backend "$a$" :engine 'ratex :callback cancelled)
      (latex-to-svg-backend "$a$" :engine 'ratex
                            :callback (lambda (outcome) (push outcome called)))
      (latex-to-svg-backend-cancel cancelled)
      (should (eq (aref (car l2s-test-processes) 1) 'run))
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (latex-to-svg-backend-tests--run-timers)
      (should (equal (mapcar (lambda (o) (plist-get o :kind)) called)
                     '(formula))))))

(ert-deftest latex-to-svg-backend-cancel-finds-a-request-handed-to-its-fallback ()
  ;; RaTeX rejected the formula and the request waits for the LaTeX
  ;; fallback: cancelling it stops that compile.
  (latex-to-svg-backend-tests--with-public-api
    (let ((cancelled (lambda (_outcome) (error "Cancelled callback called"))))
      (latex-to-svg-backend "$\\SI{3}{m}$" :engine 'ratex :fallback 'latex
                            :callback cancelled)
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (let ((latex (car l2s-test-processes)))
        (should (= (length l2s-test-processes) 2))
        (should (latex-to-svg-backend-cancel cancelled))
        (should (eq (aref latex 1) 'signal))
        (should-not latex-to-svg-backend--running)
        (should (zerop (hash-table-count latex-to-svg-backend--pending)))
        (latex-to-svg-backend-tests--run-timers)))))

(ert-deftest latex-to-svg-backend-cancel-of-an-unknown-callback-does-nothing ()
  (latex-to-svg-backend-tests--with-public-api
    (latex-to-svg-backend "$a$" :engine 'ratex :callback #'ignore)
    (should-not (latex-to-svg-backend-cancel (lambda (_outcome))))
    (should (eq (aref (car l2s-test-processes) 1) 'run))))

(ert-deftest latex-to-svg-backend-gc-deletes-old-scratch-directories ()
  ;; A scratch directory older than a day was left by an Emacs that
  ;; stopped during a compile; it goes even when entries never expire.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-tmp" t))
        (latex-to-svg-backend-cache-max-age nil))
    (unwind-protect
        (let ((old (latex-to-svg-backend--scratch-dir))
              (new (latex-to-svg-backend--scratch-dir)))
          (with-temp-file (expand-file-name "equation.tex" old) (insert "x"))
          (set-file-times old (seconds-to-time (- (float-time) (* 2 86400))))
          (latex-to-svg-backend-gc)
          (should-not (file-exists-p old))
          (should (file-directory-p new)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Tentative requests

(defmacro latex-to-svg-backend-tests--with-fmt (&rest body)
  "Run BODY with the public API, each compile loading the `.fmt' file `fmt'."
  (declare (indent 0) (debug t))
  `(latex-to-svg-backend-tests--with-public-api
     (let ((fmt (latex-to-svg-backend--format-file "fake-format")))
       (with-temp-file fmt (insert "fake format"))
       (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                  (lambda (_preamble &optional _program _package-files) fmt)))
         ,@body))))

(ert-deftest latex-to-svg-backend-failure-with-a-format-keeps-the-format ()
  ;; A compile that loaded the `.fmt' file and failed is not run again:
  ;; the failure is recorded, and the next compile loads the `.fmt' file.
  (latex-to-svg-backend-tests--with-fmt
    (let* ((doc "$\\nocommand$")
           (key (latex-to-svg-backend--cache-key doc))
           (outcomes nil))
      (latex-to-svg-backend doc :quiet t
                            :callback (lambda (o) (push o outcomes)))
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 1
       "$\\nocommand")
      (latex-to-svg-backend-tests--run-timers)
      (should (= (length l2s-test-processes) 1))
      (should (file-exists-p fmt))
      (should-not l2s-test-warnings)
      (should-not latex-to-svg-backend--running)
      (should (equal (mapcar (lambda (o) (plist-get o :kind)) outcomes)
                     '(formula)))
      (should (file-exists-p (latex-to-svg-backend--meta-file key)))
      (latex-to-svg-backend "$y$" :callback #'ignore)
      (should (string-prefix-p
               "%& " (latex-to-svg-backend-tests--tex-source
                      (latex-to-svg-backend-tests--tex-file
                       (car l2s-test-processes))))))))

(ert-deftest latex-to-svg-backend-tentative-failure-is-not-recorded ()
  ;; The callback gets the failure, and a later request compiles again.
  (latex-to-svg-backend-tests--with-fmt
    (let* ((doc "$\\nocommand$")
           (key (latex-to-svg-backend--cache-key doc))
           (outcomes nil))
      (latex-to-svg-backend doc :tentative t :quiet t
                            :callback (lambda (o) (push o outcomes)))
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 1
       "$\\nocommand")
      (latex-to-svg-backend-tests--run-timers)
      (should-not l2s-test-warnings)
      (should (equal (mapcar (lambda (o) (plist-get o :kind)) outcomes)
                     '(formula)))
      (should (equal (plist-get (car outcomes) :message)
                     "Undefined control sequence."))
      (should-not (file-exists-p (latex-to-svg-backend--meta-file key)))
      (latex-to-svg-backend doc :callback #'ignore)
      (should (= (length l2s-test-processes) 2)))))

(ert-deftest latex-to-svg-backend-tentative-merged-with-a-normal-request ()
  ;; A compile is tentative only when every request is: with a normal one
  ;; waiting too, the failure is recorded.
  (latex-to-svg-backend-tests--with-fmt
    (let ((doc "$\\nocommand$"))
      (latex-to-svg-backend doc :tentative t :quiet t :callback #'ignore)
      (latex-to-svg-backend doc :quiet t :callback #'ignore)
      (should (= (length l2s-test-processes) 1))
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 1
       "$\\nocommand")
      (latex-to-svg-backend-tests--run-timers)
      (should (file-exists-p (latex-to-svg-backend--meta-file
                              (latex-to-svg-backend--cache-key doc)))))))

(ert-deftest latex-to-svg-backend-tentative-failure-is-never-recorded ()
  ;; Without a `.fmt' file, and with RaTeX, a tentative failure is not
  ;; recorded either, so a later request compiles again.
  (latex-to-svg-backend-tests--with-public-api
    (let ((doc "$\\nocommand$"))
      (latex-to-svg-backend doc :tentative t :quiet t :callback #'ignore)
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 1
       "$\\nocommand")
      (latex-to-svg-backend doc :engine 'ratex :tentative t :quiet t
                            :callback #'ignore)
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (latex-to-svg-backend-tests--run-timers)
      (dolist (engine '(latex ratex))
        (should-not (file-exists-p
                     (latex-to-svg-backend--meta-file
                      (latex-to-svg-backend--cache-key doc engine)))))
      (latex-to-svg-backend doc :callback #'ignore)
      (latex-to-svg-backend doc :engine 'ratex :callback #'ignore)
      (should (= (length l2s-test-processes) 4)))))

(ert-deftest latex-to-svg-backend-tentative-stays-tentative-in-the-fallback ()
  ;; RaTeX rejects the formula; the LaTeX fallback fails too: the
  ;; request is still tentative there, so neither failure is recorded.
  (latex-to-svg-backend-tests--with-fmt
    (let ((doc "$\\nocommand$")
          (outcomes nil))
      (latex-to-svg-backend doc :engine 'ratex :fallback 'latex
                            :tentative t :quiet t
                            :callback (lambda (o) (push o outcomes)))
      (latex-to-svg-backend-tests--fail-ratex (car l2s-test-processes))
      (latex-to-svg-backend-tests--fail-latex
       (car l2s-test-processes) doc "Undefined control sequence." 1
       "$\\nocommand")
      (latex-to-svg-backend-tests--run-timers)
      (should (= (length l2s-test-processes) 2))
      (should-not (file-exists-p (latex-to-svg-backend--meta-file
                                  (latex-to-svg-backend--cache-key doc))))
      (should (equal (mapcar (lambda (o) (plist-get o :engine)) outcomes)
                     '(latex))))))

(provide 'latex-to-svg-backend-tests)

;;; latex-to-svg-backend-tests.el ends here
