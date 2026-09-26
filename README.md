# latex-to-svg-backend

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/latex-to-svg-backend-badge.svg)](https://melpa.org/#/latex-to-svg-backend)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-backend-badge.svg)](https://stable.melpa.org/#/latex-to-svg-backend)
[![melpazoid](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg-backend)](LICENSE)

A small, **buffer-agnostic** Emacs library that turns a LaTeX math string into an SVG image suitable for overlaying in a buffer. It is the rendering backend behind [`agent-shell-math-renderer`](https://github.com/alberti42/agent-shell-math-renderer) and the [`latex-to-svg`](https://github.com/alberti42/latex-to-svg) preview stack for Org and Markdown. A front-end does its own equation *detection* and image *placement*; the typesetting, caching and sizing is done by the banckend.

Used by [**`latex-to-svg`**](https://github.com/alberti42/latex-to-svg) (Org/Markdown math preview) and [**`agent-shell-math-renderer`**](https://github.com/alberti42/agent-shell-math-renderer) (math in `agent-shell` output); see [Related packages](#related-packages).

## Why

Equations are compiled once and then recolored and rescaled **without recompiling** — the two things that are expensive if you bake color/size into the render:

- **Each equation compiles once.** The cache file is named after the equation itself (the SHA-1 of the LaTeX, the preamble and the style), so identical input always finds its own file and the cache is shared across every front-end and buffer.
- **Color-independent SVG.** `dvisvgm --currentcolor` emits the default ink as the literal token `currentColor`, substituted with the buffer foreground at display time. A theme switch re-tints from cache — no recompile. The image background is transparent, so it always matches the buffer.
- **Size-independent SVG.** Compiled at `dvisvgm --scale=1` (natural point dimensions, glyphs as outline paths) and scaled at display time via `create-image`'s `:scale`, computed from the buffer font height so equations track the font — again no recompile.
- **In-memory image cache.** On top of the on-disk SVG cache, each ready-to-display image (the SVG already tinted and scaled for the current buffer) is memoized for the session, keyed by content + color + scale. Re-showing an equation you've already displayed — revisiting a buffer, scrolling back, a redisplay — is then an instant hash lookup, with no disk read and no recompile. Sizes and colors coexist as separate entries, so a font or theme change just adds one.

## Related packages

`latex-to-svg-backend` is a library, not a preview command: it turns one LaTeX string into one image and leaves *finding* equations and *placing* images to a front-end. Two front-ends are built on it today:

- [**`latex-to-svg`**](https://github.com/alberti42/latex-to-svg) — previews LaTeX math in **Org and Markdown** buffers (and other markups) as SVG. A shared front-end core (`latex-to-svg-frontend`) plus thin per-mode adaptors detect math with a blank-line-bounded scanner and overlay each occurrence with an SVG typeset here; because the backend renders its input verbatim, sizing follows from the delimiters. A drop-in replacement for built-in `org-latex-preview` that adds recolor-on-theme-switch and rescale-on-zoom straight from cache.
- [**`agent-shell-math-renderer`**](https://github.com/alberti42/agent-shell-math-renderer) — renders LaTeX math in [`agent-shell`](https://github.com/xenodium/agent-shell)'s streamed markdown output. Display and inline math in an agent's response are shown as theme-matched SVGs while the original LaTeX stays in the buffer, so copy and save round-trip renderable source. It uses this library for the typesetting.

Because the cache is named after the equation's content, an equation that appears in both an Org buffer and an agent's chat compiles only once, shared across both.

Several other Emacs packages preview LaTeX for the user; a few do, under the hood, the same string-to-image step this library does. How they relate:

| Package | Renders → output | Tied to | Recolor | Numbers | `\eqref` | `.fmt` |
| --- | --- | --- | --- | --- | --- | --- |
| **latex-to-svg-backend** (this) | `latex`+`dvisvgm` or RaTeX → SVG | any buffer / bare string | yes | yes¹ | yes¹ | yes |
| AUCTeX preview-latex | `latex`+`preview.sty` → PNG/SVG² | AUCTeX + `.tex` | no | yes | yes | no |
| [`texfrag`](https://github.com/TobiasZawada/texfrag) | AUCTeX `preview.el` → PNG/SVG² | AUCTeX; many modes | no | yes | yes | no |
| Org `org-latex-preview` (built-in) | `latex`+`dvipng`/`dvisvgm` → PNG/SVG | Org | no | no | no | no |
| [tecosaur/karthink `org-latex-preview`](https://code.tecosaur.net/tec/org-mode) (fork) | `latex`+`dvisvgm` (`.fmt`) → SVG | Org branch (fork) | yes | partial | partial | yes |
| [`org-latex-impatient`](https://github.com/yangsheng6810/org-latex-impatient) | MathJax → SVG (child frame) | Org | no | no | no | no |
| [`org-xlatex`](https://github.com/ksqsf/org-xlatex) | MathJax/KaTeX → xwidget | Org + xwidgets | no | no | no | no |
| [`latex-math-preview`](https://gitlab.com/latex-math-preview/latex-math-preview) | `latex`+`dvipng` → PNG | interactive command | no | no | no | no |

¹ via the [`latex-to-svg`](https://github.com/alberti42/latex-to-svg) front-end (the backend supplies the numbering metadata; the front-end assigns numbers and resolves `\ref` / `\eqref`). ² SVG output requires `preview-dvisvgm`.

What sets this stack apart is that it pulls together strengths that used to live in separate tools:

- **Numbered equations + working `\ref` / `\eqref`** — the AUCTeX-based packages get these by compiling a whole `.tex`; here the [`latex-to-svg`](https://github.com/alberti42/latex-to-svg) front-end assigns each block's numbers (folded in as a `\setcounter`) and reads the true counter back through the backend's compile-metadata sidecar, so every fragment still compiles alone.
- **Recolour + rescale from cache** — a theme switch, or a font/zoom change, updates previews with no LaTeX run; the others bake the colour and size into the image and must re-run LaTeX.
- **Fast builds** — `.fmt` preamble precompilation (see [Preamble precompilation](#preamble-precompilation-fmt)).
- **A shared, bare-string cache** — keyed by the equation's content and shared across front-ends and sessions, and the engine takes a bare string, so it works outside a `.tex` document (for example, math in an agent's chat output).

The last two fall out of compiling each equation on its own and naming it by content.

The closest relative is the in-progress next-generation `org-latex-preview` by tecosaur and karthink: it also caches a color-independent (`currentColor`) SVG that re-tints from cache on a theme change, and pioneered the `.fmt` preamble precompilation this library adopts (see [Preamble precompilation](#preamble-precompilation-fmt)). The difference is packaging — it ships as part of a patched Org branch and is Org-only, while `latex-to-svg-backend` is a standalone library any front-end (or a bare string, in any buffer) can call.

Equation numbering used to be the gap: the AUCTeX-based packages compile a whole document, so `\ref` / `\eqref` and equation numbers come out right on their own, whereas here each fragment is compiled alone. The [`latex-to-svg`](https://github.com/alberti42/latex-to-svg) front-end closes it — it scans the buffer to assign each block's numbers (folded into the fragment as a `\setcounter`), reads the true final counter back through the backend's compile-metadata sidecar, and renders `\ref` / `\eqref` as the resolved number with click-to-jump. To our knowledge, this is the only stack that combines numbered equations **and** working `\ref` / `\eqref` links **and** `.fmt` precompilation **and** recolour/rescale from cache: the tecosaur/karthink fork has `.fmt` and cache-recolour but only partial numbering and no full cross-references, while the AUCTeX packages have numbering and references but no `.fmt` and no cache-recolour.

## Requirements

- Emacs 29.1+ with SVG image support.
- The programs of one of the two [engines](#engines) on `exec-path`:
  - LaTeX (the default): `latex` and `dvisvgm`, from any TeX distribution. Optionally the `mylatexformat` package (`mylatexformat.ltx`, bundled with most TeX distributions) for preamble precompilation. Absent, the backend simply skips the speedup — see [Preamble precompilation](#preamble-precompilation-fmt).
  - RaTeX: its `render-svg` program. No TeX installation.

  Without them, a placeholder panel boxing the raw LaTeX is shown instead (or set `latex-to-svg-backend-use-placeholder`).

## Installation

It is on [MELPA](https://melpa.org/#/latex-to-svg-backend):

```
M-x package-install RET latex-to-svg-backend RET
```

Usually you do not install it yourself, though. This is a *library*: a
front-end (the [`latex-to-svg`](https://github.com/alberti42/latex-to-svg)
preview stack, or
[`agent-shell-math-renderer`](https://github.com/alberti42/agent-shell-math-renderer))
names it in `Package-Requires`, so installing the front-end brings it in.

To track the development version instead of the MELPA snapshot:

```elisp
;; use-package + :vc (Emacs 30+)
(use-package latex-to-svg-backend
  :vc (:url "https://github.com/alberti42/latex-to-svg-backend" :rev :newest))

;; use-package + straight
(use-package latex-to-svg-backend
  :straight (latex-to-svg-backend :type git :host github
                          :repo "alberti42/latex-to-svg-backend"))

;; elpaca
(elpaca (latex-to-svg-backend :host github :repo "alberti42/latex-to-svg-backend"))

;; Emacs 29+ builtin, no package manager
(package-vc-install "https://github.com/alberti42/latex-to-svg-backend")
```

The package (feature) is `latex-to-svg-backend`, and so is the recipe *name*
(the feature you `require`); the repository is
**`alberti42/latex-to-svg-backend`**.

## Engines

The `:engine` argument of `latex-to-svg-backend` chooses the program that typesets an equation:

- **`latex`** (the default, also `nil`) runs `latex` and `dvisvgm`. It is full LaTeX: any package the preamble loads, any macro it defines.
- **`ratex`** runs `render-svg` from [RaTeX](https://github.com/erweixin/RaTeX), a math renderer written in Rust that parses KaTeX's syntax. It is one program and needs no TeX installation, but it typesets only the math KaTeX supports, and it loads no packages.

Both produce the same color- and size-independent SVG, cropped to the ink, so everything under [API](#api) works the same with either. The engine is part of the cache key, so each engine's SVGs stay cached when a caller switches to the other.

The engine is chosen per call, like `:color`: a front-end owns the user's choice and passes it. The backend has no option for it. A caller that passes no `:engine`, such as [`agent-shell-math-renderer`](https://github.com/alberti42/agent-shell-math-renderer) today, gets the LaTeX engine. In the [`latex-to-svg`](https://github.com/alberti42/latex-to-svg) front-end, `latex-to-svg-frontend-engine` chooses it, also as a file- or directory-local variable, and a comment at the top of a display equation (`% engine=ratex`) chooses the engine for that equation or skips it; see that package's README.

To use RaTeX, download the archive for your system from the [RaTeX releases](https://github.com/erweixin/RaTeX/releases) (`ratex-cli-<version>-<target>.tar.gz`) and put its `render-svg` on `exec-path`, or set `latex-to-svg-backend-ratex-program` to its path. A front-end then asks for it:

```elisp
(latex-to-svg-backend "$x^2$" :engine 'ratex :callback #'my-refresh)
```

What changes with RaTeX, from RaTeX v0.1.14:

- **No preamble.** RaTeX parses one formula at a time. `latex-to-svg-backend-ratex-macros` is put in front of every formula, so `\newcommand`, `\renewcommand` and `\def` there apply to every equation. `\newcommand` signals an error for a name RaTeX already defines (`\R`, `\ket`, …); use `\renewcommand` or `\def` for those.
- **No packages.** A command KaTeX does not have fails with *Undefined control sequence*: siunitx's `\SI` and `\unit`, `\DeclareMathOperator` (use `\operatorname`), `\label`, `\setcounter`. mhchem's `\ce` and `\pu` are built in.
- **Delimiters.** RaTeX rejects `\(` and `\[`, so the backend removes the outer `$…$`, `\(…\)`, `$$…$$` or `\[…\]` and typesets in text style for the first two and in display style otherwise. An environment (`\begin{align}…`) is passed as is. `%` comments are removed and the lines joined, because `render-svg` reads one formula per line.
- **Numbering.** Each `equation` or `align` is numbered from (1), `\notag` works, and `\tag{N}` sets a number. There is no counter to set and no compile metadata, so `:metadata` is ignored. The [`latex-to-svg`](https://github.com/alberti42/latex-to-svg) front-end numbers equations with RaTeX by putting `\tag{N}` on each numbered row and removing every `\label` from what RaTeX receives.
- **Look.** The glyphs are KaTeX's fonts, and the layout is RaTeX's implementation of KaTeX's, so it can differ from TeX's in detail. Text in `\text{}` that the KaTeX fonts lack is drawn in a system font.
- **Speed.** A new equation compiles in 6–7 ms instead of 313–316 ms (medians); see [Benchmark](#benchmark).

## Benchmark

The time to compile a new equation, with each engine, for the 20 equations in [`dev/latex-to-svg-backend-benchmark.el`](dev/latex-to-svg-backend-benchmark.el) (inline and display math, `equation`, `align`, matrices, `cases`). Every run starts from an empty cache, so every equation compiles. A cached equation costs the same with either engine, because neither runs: showing it again, a theme switch and a font change are all cache hits.

| | LaTeX (`latex` + `dvisvgm`, `.fmt`) | RaTeX (`render-svg`) |
| --- | ---: | ---: |
| One equation at a time, median | 313–316 ms | 6–7 ms |
| One equation at a time, fastest to slowest | 300–353 ms | 6–12 ms |
| All 20 queued at once, until the last is ready | 1321–1394 ms | 48–55 ms |
| One-time `.fmt` build | 377–396 ms | — |

*One at a time* compiles an equation, waits for it, then starts the next. *All at once* is what a front-end does when it opens a buffer; the compiles then run in parallel, which brings LaTeX to 66–70 ms per equation and RaTeX to 2–3 ms. Each figure is the range over three rounds.

The LaTeX runs used the default preamble. Loading `physics`, `stmaryrd`, `siunitx` and `mathtools` through `latex-to-svg-backend-appended-preamble` as well changed the median to 335–338 ms, the batch to 1366–1379 ms and the `.fmt` build to 517–529 ms: the `.fmt` loads the packages once, so each equation barely pays for them.

Measured in a running Emacs 32.0.50 with native compilation and the package byte-compiled, on an Apple M2 (8 cores) under macOS 27.0, with TeX Live 2026 (pdfTeX 1.40.29), dvisvgm 3.6 and the RaTeX v0.1.14 release of `render-svg`.

To run it yourself from a checkout, byte-compile the package first. On the same machine, the commands below gave RaTeX 7 ms per equation and 79–80 ms for the batch, and LaTeX 330 ms and 1418–1449 ms. Loaded from source, without the first command, the Elisp that crops RaTeX's SVG runs uncompiled, and RaTeX took 9–10 ms and 130–133 ms.

```sh
emacs -Q -batch -L . -f batch-byte-compile latex-to-svg-backend*.el
emacs -Q -batch -L . -l dev/latex-to-svg-backend-benchmark.el \
      -f latex-to-svg-backend-benchmark-batch
```

In a running Emacs, load `dev/latex-to-svg-backend-benchmark.el` and call `M-x latex-to-svg-backend-benchmark`. Either way the LaTeX runs use your current preamble and settings, and your own cache is not touched.

## API

```elisp
(latex-to-svg-backend LATEX &key callback metadata engine rescale-by color background padding font-height)
```

`LATEX` is placed **verbatim** in the LaTeX document body, so pass valid body LaTeX — math with its delimiters (`$x$`, `\(x\)`, `\[x\]`) or a full environment (`\begin{equation}…\end{equation}`). The delimiters also decide inline vs display sizing; the backend is deliberately unaware of that distinction (a front-end that has bare bodies wraps them itself). Equation numbering, if a front-end wants it, is just a `\setcounter{equation}{N}` prepended to the body — it folds into the content hash for free.

Returns an image now when one can be produced synchronously (cache / on-disk SVG / placeholder), else `nil` after scheduling an asynchronous compile; `CALLBACK` (a zero-argument function) is invoked once the SVG is ready, so the caller can re-query (`latex-to-svg-backend` again → now returns the image) and place it. Concurrent requests for the same equation are coalesced onto a single compile.

`ENGINE` is `latex` (the default, also `nil`) or `ratex`; see [Engines](#engines). Any other value signals an error.

`RESCALE-BY` (default `1.0`) multiplies the display size of this one call on top of `latex-to-svg-backend-font-scale`. The backend has no inline/display awareness, so a front-end that wants display equations a touch larger than inline passes, say, `:rescale-by 1.1` for display and nothing for inline. It is a display-time scale only — same on-disk SVG, no recompile — and folds into the in-memory image cache key, so both sizes coexist. `METADATA` is documented under [Compile metadata](#compile-metadata-eld-sidecar) below.

`COLOR` and `BACKGROUND` override, for this one call, the tint and the box color (both color strings — `#rrggbb` or any name `color-name-to-rgb` understands). `COLOR` defaults to the buffer foreground (`latex-to-svg-backend-foreground-color`), which tracks the theme; `BACKGROUND` defaults to `nil` = transparent, so equations blend into the buffer. `PADDING` grows the `BACKGROUND` box beyond the ink — the SVG viewport is enlarged and a filled `<rect>` baked in — and scales with the equation; `nil` / `0` crops the box to the ink. It is either a number of pt, applied to all four sides, or a list of one to four numbers read in **CSS order**:

| Spec | Sides |
| --- | --- |
| `6` or `(6)` | all four |
| `(2 6)` | vertical, horizontal |
| `(2 6 4)` | top, horizontal, bottom |
| `(2 6 4 8)` | top, right, bottom, left |

So a left gutter and nothing else is `:padding '(0 0 0 6)`. Each dimension grows by the sum of its two sides and the origin shifts by the left/top ones, so the ink stays put relative to the sides that were not padded. A malformed spec (wrong length, a non-number, a negative side) signals an error rather than silently rendering an unpadded box. Like `RESCALE-BY` they apply at display time only — same on-disk SVG, no recompile — and fold into the image cache key so variants coexist. The backend has no tint policy of its own beyond following the buffer face: a front-end owns any user-facing “fixed color” / “boxed equation” preference and passes it here.

`FONT-HEIGHT` (pixels) is the buffer font height to size against. A front-end that knows the buffer's actual display frame measures `default-font-height` there and passes it, so sizing never depends on which frame happens to be selected (e.g. an async callback while a TTY/daemon frame is current). When omitted, the selected frame is measured if it is graphical. When **no** height is known (omitted *and* the selected frame is non-graphical — a background/daemon render of a buffer shown in no window), the backend still ensures the size-independent SVG is compiled and cached, but returns `nil` rather than sizing against a guess — the front-end re-queries once the buffer is displayed (its display hook already does this for theme/font changes) and the image is built then, from cache, with no recompile. The `latex` → `dvisvgm` **compile** never needs a frame; only building the display image does.

The image is tinted to the current buffer foreground and scaled to the buffer font at build time, so call it within the target buffer.

Helpers a front-end typically needs for its refresh policy:

| Function | Purpose |
| --- | --- |
| `latex-to-svg-backend-available-p` | SVG build support + graphical (or non-graphic opt-in) |
| `latex-to-svg-backend-tools-available-p` | the programs of an engine on `exec-path`: `latex` + `dvisvgm`, or `render-svg` with the argument `ratex` |
| `latex-to-svg-backend-appearance` | `(FOREGROUND BACKGROUND FONT-HEIGHT)` signature to detect color/size change; takes an optional `font-height` so it matches the render |
| `latex-to-svg-backend-display-scale` | the `:scale` mapping the equation to the buffer font; takes an optional `font-height`, and returns `nil` when no height is known (defer) |
| `latex-to-svg-backend-foreground-color` | current tint color (`#rrggbb`) |
| `latex-to-svg-backend-invalidate` | forget a cached render (delete its on-disk SVG + in-memory images, and its `.eld` sidecar) so the next call recompiles — an escape hatch for a stale/corrupt cache; an optional second argument names the engine, as for `:engine` |
| `latex-to-svg-backend-metadata` | read back compile metadata for a LaTeX body (see below), on cache hit or miss; an optional second argument names the engine |

### Compile metadata (`.eld` sidecar)

A compile can pair a value the caller already knows with a number the *compile* produces, and cache the pair next to the SVG — so a front-end can read it back **without recompiling** (e.g. the range of equation numbers a block shows). It is opt-in and the backend stays unaware of what the numbers mean.

The division of labour: the caller passes what it knows (`INITIAL`) as a Lisp value via `:metadata`; only the thing the compile computes (`FINAL`) travels through LaTeX, `\typeout`-ed on a line beginning with `latex-to-svg-backend-metadata-prefix`:

```elisp
(latex-to-svg-backend
  (concat "\\setcounter{equation}{6}%\n"          ; K = 6
          "\\begin{equation}x=1\\end{equation}\n"
          "\\typeout{L2S \\arabic{equation}}%\n") ; -> FINAL in the log
  :callback #'my-refresh
  :metadata 7)                                    ; INITIAL = K+1, from Elisp
```

With `latex-to-svg-backend-metadata-prefix` set to `"L2S"`, a successful compile takes the first integer on a matching log line (`FINAL`), pairs it with `:metadata` (`INITIAL`), and writes `<hash>.eld` beside `<hash>.svg`:

```elisp
(:nums (INITIAL . FINAL))     ; e.g. (:nums (7 . 7))
```

`(latex-to-svg-backend-metadata BODY)` returns that plist (or `nil` if absent/corrupt).  Here the block shows equation numbers `INITIAL`…`FINAL` (just `(7)`); `FINAL < INITIAL` means it produced none.

For an equation you *don't* want to track, do nothing extra: call `(latex-to-svg-backend BODY …)` with no `:metadata` and inject no `\typeout`. No sidecar is written and `(latex-to-svg-backend-metadata BODY)` returns `nil` — the whole mechanism is inert unless you opt in (and stays off entirely while `latex-to-svg-backend-metadata-prefix` is `nil`, its default). So `nil` is simply the normal answer for any un-probed equation; there is no "no number" sentinel to handle. `latex-to-svg-backend-invalidate` deletes the `.eld` with the SVG. `\typeout` has no visual effect, so the SVG is byte-identical to an un-probed one (only its content hash differs). Keep the emitted line short — TeX wraps log lines near column 80.

### Sketch of a front-end

```elisp
(defun my-place (buffer beg end latex)   ; LATEX is valid body LaTeX
  (with-current-buffer buffer
    (if-let ((img (latex-to-svg-backend latex)))
        (my-overlay buffer beg end img)          ; cached / placeholder
      (let ((s (copy-marker beg)) (e (copy-marker end)))
        (latex-to-svg-backend latex
          :callback (lambda ()
                      (with-current-buffer buffer
                        (my-overlay buffer s e (latex-to-svg-backend latex)))))))))
```

## Customization

`M-x customize-group RET latex-to-svg-backend` shows the options of both engines, with those of each engine in its own subgroup (`latex-to-svg-backend-latex`, `latex-to-svg-backend-ratex`). Which engine each option and command belongs to (the `latex-to-svg-backend-` prefix is left out):

| Both engines | LaTeX only | RaTeX only |
| --- | --- | --- |
| `-cache-directory` | `-latex-program` | `-ratex-program` |
| `-cache-max-age` | `-dvisvgm-program` | `-ratex-macros` |
| `-gc-interval` | `-preamble` | |
| `-font-scale` | `-appended-preamble` | |
| `-use-placeholder` | `-line-width` | |
| `-render-on-non-graphic` | `-metadata-prefix` | |
| `-svg-dpi` | `-precompile` | |
| `M-x …-gc`, `…-clear-cache`, `…-invalidate` | `M-x …-flush-format` | |

There is no option for the engine: the caller chooses it per call (see [Engines](#engines)).

The functions under [API](#api) work with both; `latex-to-svg-backend-metadata` returns `nil` for an equation RaTeX rendered.

| Variable | Default | Purpose |
| --- | --- | --- |
| `latex-to-svg-backend-latex-program` | `"latex"` | the `latex` binary |
| `latex-to-svg-backend-dvisvgm-program` | `"dvisvgm"` | the `dvisvgm` binary |
| `latex-to-svg-backend-preamble` | `standalone[varwidth]` + `amsmath`/`xcolor` | the document class and base packages |
| `latex-to-svg-backend-appended-preamble` | `""` | extra preamble lines (your macros, packages) appended to the base |
| `latex-to-svg-backend-line-width` | `nil` | max equation width (LaTeX dim); raise it (e.g. `"20cm"`) so wide numbered equations keep their number on one line — see below |
| `latex-to-svg-backend-cache-directory` | `$XDG_CACHE_HOME/emacs/latex-to-svg/` | cache root; holds `svg/` (sharded SVGs + sidecars) and `fmt/` (`.fmt` files) — see below |
| `latex-to-svg-backend-cache-max-age` | `90` | GC deletes equations untouched for this many days (`nil` = no age limit) |
| `latex-to-svg-backend-gc-interval` | `1` | minimum days between automatic GC runs (`nil` = no automatic GC) |
| `latex-to-svg-backend-font-scale` | `1.0` | equation size relative to the buffer font (1.0 = match) |
| `latex-to-svg-backend-use-placeholder` | `nil` | force the raw-LaTeX placeholder instead of compiling |
| `latex-to-svg-backend-render-on-non-graphic` | `nil` | allow rendering on a non-graphical frame |
| `latex-to-svg-backend-svg-dpi` | `96.0` | points→pixels constant for sizing; rarely needs changing |
| `latex-to-svg-backend-metadata-prefix` | `nil` | `nil` = off; the `\typeout` prefix enabling `.eld` compile-metadata capture (above) |
| `latex-to-svg-backend-precompile` | `t` | preamble precompilation to a `.fmt` (below) |
| `latex-to-svg-backend-ratex-program` | `"render-svg"` | RaTeX's `render-svg` binary |
| `latex-to-svg-backend-ratex-macros` | `""` | macro definitions put in front of every formula RaTeX renders |

### Controlling the width of numbered equations (`latex-to-svg-backend-line-width`)

You normally never touch this, and it only concerns *numbered* equations. A numbered display puts its number flush right at the equation's max width (the `varwidth` box, default `\linewidth` ≈ 345pt) — the usual right-margin placement you see in any document. The one case where the default bites is an equation *wider* than that margin: TeX then drops the number onto a second line. If you have such equations, set `latex-to-svg-backend-line-width` to a LaTeX dimension wide enough for your widest one (e.g. `"20cm"`) and the number stays on the line. All this does is move the right margin — out for wide equations, or *in* (a smaller value, e.g. `"6cm"`) to tuck the number closer when every equation is short.

Nothing is ever clipped: math cannot line-break, so an equation wider than the box just overflows it and is cropped to its full ink either way. Setting the width too small therefore doesn't truncate anything — its only effect is to wrap the number onto a second line (the very thing you'd be avoiding), so keep it at or above your widest numbered equation. Unnumbered content ignores this setting entirely. The value folds into the cache key, so changing it re-renders.

### Cache location & garbage collection

Every unique equation compiles to a color- and size-independent SVG named by the SHA-1 of its LaTeX + preamble + style, cached under `latex-to-svg-backend-cache-directory` (default `$XDG_CACHE_HOME/emacs/latex-to-svg/`, or `~/.cache/emacs/latex-to-svg/`). The cache **persists across sessions** and is **shared across every front-end and buffer** — an equation that appears in an Org buffer and an agent's chat compiles once. Because the SVG is color- and size-independent, a theme switch or font/zoom change is a cache *hit*, never a recompile, so the cache doesn't churn the way a color-baked one does.

Lookup is two-tier: a request is served first from the **in-memory image cache** (a ready-to-display image, keyed by content + color + scale — see [Why](#why)), then from the **on-disk SVG**, and only a miss on both triggers a compile that writes a new SVG. So re-displaying equations within a session never touches disk, and the on-disk tree only grows when a genuinely new (or evicted) equation is rendered.

The cache root is organised into two subdirectories (plus a `gc-timestamp` housekeeping file):

```
$XDG_CACHE_HOME/emacs/latex-to-svg/
├── svg/           # equation SVGs, sharded 256 ways
│   └── ab/ abcd….svg  abcd….eld  abcd….log
├── fmt/           # precompiled preamble format files
│   └── <fkey>.fmt
└── gc-timestamp
```

SVGs are **sharded** into 256 buckets under `svg/`, named by the first two hex characters of the content hash (`svg/ab/abcd….svg`, with the `.eld` sidecar and any compile `.log` alongside), so no single directory accumulates every equation.

Stale entries are pruned by an **age-based garbage collector**. Each SVG's modification time is a last-use hint, bumped whenever the equation is (re)loaded, so `latex-to-svg-backend-gc` deletes only equations untouched for `latex-to-svg-backend-cache-max-age` days (default 90); a pruned one simply recompiles when next needed. GC runs automatically at most once per `latex-to-svg-backend-gc-interval` day (default 1), coordinated through an on-disk timestamp and an idle timer — so several sessions sharing the cache don't each run it, and a daemon left running for days still collects daily. Set `-gc-interval` to `nil` to disable automatic GC (you can still call it by hand), or `-cache-max-age` to `nil` to keep entries forever.

Three interactive commands manage the cache directly:

| Command | Effect |
| --- | --- |
| `latex-to-svg-backend-gc` | run the age-based prune now (returns `(DELETED . BYTES-FREED)`) |
| `latex-to-svg-backend-clear-cache` | delete **all** cached equation SVGs (with their `.eld`/`.log` siblings) and the in-memory image cache; keeps `.fmt` files |
| `latex-to-svg-backend-invalidate` | forget one equation's cached render (its SVG, `.eld`, and in-memory images) so it recompiles — an escape hatch for a stale/corrupt entry |

### Preamble precompilation (`.fmt`)

Every equation is its own tiny LaTeX document, so each compile re-reads the class and every package in the preamble (`amsmath`, `xcolor`, and whatever you add via `latex-to-svg-backend-appended-preamble`). That parsing dominates the runtime of a small equation. With `latex-to-svg-backend-precompile` (default `t`) the backend dumps the preamble **once** to a LaTeX format file (`.fmt`) using the [`mylatexformat`](https://ctan.org/pkg/mylatexformat) package, keyed by the preamble text, and every equation compile then loads it via a `%&` first line instead of re-parsing the packages — typically **25–40% faster per equation**, more with a heavier preamble.

It is a pure optimization with a graceful fallback: when `mylatexformat.ltx` isn't on the TeX search path, or the dump fails, or a compile that used the format later fails, the backend transparently reverts to embedding the full preamble. A stale format after a TeX toolchain upgrade is detected (the LaTeX binary is newer than the `.fmt`) and rebuilt automatically; `M-x latex-to-svg-backend-flush-format` is the manual escape hatch. Set `latex-to-svg-backend-precompile` to `nil` to disable it entirely.

The `%&`-loaded `.fmt` approach is borrowed from the work of Karthik Chikmagalur (karthink) and TEC (tecosaur) on fast Org math preview. It started as karthink's proof-of-concept [`org-preview`](https://github.com/karthink/org-preview) (now archived); the `.fmt`-based `org-latex-preview` it grew into lives in a [fork of Org mode](https://code.tecosaur.net/tec/org-mode.git) and is not part of upstream Org.

Preview size is derived deterministically from the buffer font height and `-svg-dpi` (SVG `pt` = dpi/72 px). Earlier versions measured this per-frame with `image-size`, which proved unreliable on some ports (returning wildly different pixel sizes for the same undisplayed SVG) and made preview sizes non-deterministic — that measurement was removed in 0.2.2.

## Troubleshooting

The backend puts your LaTeX **verbatim** into a `standalone` document with a
deliberately **minimal** preamble (`amsmath` + `xcolor`). This is a design
choice, not an oversight: LaTeX has countless edge cases (extra packages,
macros, encodings), and pulling them all into the default preamble would bloat
it — every equation would compile slower, users would be forced to install a
large TeX distribution for features they never use, and the more packages we
load the higher the chance of version-based conflicts between them. So we keep
the base lean and give you `latex-to-svg-backend-appended-preamble` to add
exactly what a given input needs. It folds into the cache key, so changing it
re-renders. A few common cases:

- **`Unicode character ... not set up for use with LaTeX`** — the input
  contains a raw Unicode character the base preamble doesn't know. A frequent
  offender is a *combining* math accent such as `x̂` (an `x` followed by
  U+0302 COMBINING CIRCUMFLEX ACCENT), which agents sometimes emit instead of
  `\hat{x}`. Add the [`pdfmathaccents`](https://ctan.org/pkg/pdfmathaccents)
  package, which maps combining accents onto their math-accent commands:

  ```elisp
  (setq latex-to-svg-backend-appended-preamble "\\usepackage{pdfmathaccents}")
  ```

  More generally, any missing character can be declared with `\DeclareUnicodeCharacter`
  (from `inputenc`) or handled by loading the appropriate package.

- **A macro or environment the input uses isn't defined** (`Undefined control
  sequence`) — load the package that provides it (or define the macro) via
  `latex-to-svg-backend-appended-preamble`.

If a compile fails, the backend warns with a clickable link to the LaTeX
`.log` (kept next to the cached SVG under `svg/`), which is the fastest way to
see exactly what TeX objected to. With the RaTeX engine the same link opens
RaTeX's output, which names the command it could not parse (see
[Engines](#engines) for what RaTeX does not support).

## Tests

```sh
emacs -batch -l ert -l tests/latex-to-svg-backend-tests.el -f ert-run-tests-batch-and-exit
```

The suite runs without a TeX toolchain or a graphical display (graphical inputs are stubbed).

## License

GPL-3.0-or-later.
