# latex-to-svg-backend

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/latex-to-svg-backend-badge.svg)](https://melpa.org/#/latex-to-svg-backend)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-backend-badge.svg)](https://stable.melpa.org/#/latex-to-svg-backend)
[![melpazoid](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg-backend/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg-backend)](LICENSE)

A **buffer-agnostic** Emacs library that turns one LaTeX math string into one SVG image, compiled with one of three engines: [LaTeX](https://www.latex-project.org/) (`latex` → `dvisvgm`), [texres](https://github.com/leoliu0/texres) (`pdflatex` → `pdftocairo`, no TeX Live installation) or [RaTeX](https://github.com/erweixin/RaTeX) (`render-svg`, no TeX installation); see [Engines](#engines). Equations are compiled once and then recolored and rescaled **without recompiling**, so an image follows the buffer's theme and font size. A front-end does its own equation *detection* and image *placement*; the typesetting, caching and sizing is done by the backend. The front-ends are [**`latex-to-svg`**](https://github.com/alberti42/latex-to-svg) (math in Org and Markdown buffers) and [**`agent-shell-math-renderer`**](https://github.com/alberti42/agent-shell-math-renderer) (math in `agent-shell` output); see [Related packages](#related-packages).

Disclosure: Written with AI assistance (Claude). Every change is reviewed and tested by the author, and design decisions are the author's.

## Why

Equations are compiled once and then recolored and rescaled **without recompiling** — the two things that are expensive if you bake color/size into the render:

- **Each equation compiles once.** The cache file is named after the equation itself (the SHA-1 of the LaTeX, the preamble and the style), so identical input always finds its own file and the cache is shared across every front-end and buffer.
- **Color-independent SVG.** The default ink is the literal token `currentColor` in the SVG (`dvisvgm --currentcolor` writes it; for RaTeX the backend replaces a marker color with it), substituted with the caller's `:color` at display time. A theme switch re-tints from cache — no recompile. The image background is transparent, so it always matches the buffer.
- **Size-independent SVG.** Every engine compiles at a 10pt em (`dvisvgm --scale=1`; RaTeX `--font-size 40 --dpr 0.25`), with glyphs as outline paths. At display time the image is given its width in pixels, so the equation's lowercase letters are as tall as the text's around it, and equations track the font — also here no recompile. See [Size and baseline](#size-and-baseline).
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
- The programs of one of the three [engines](#engines) on `exec-path`:
  - LaTeX (the default): `latex` and `dvisvgm` 3.1 or later, from any TeX distribution (TeX Live 2024 or later ships it). dvisvgm 3.1 added `--currentcolor`, which makes the SVG color-independent.
  - RaTeX: its `render-svg` program, v0.1.14 or later. No TeX installation. What [Engines](#engines) says about RaTeX was checked with v0.1.14.
  - texres: `texres` 0.7.8 or later, and `pdftocairo` from Poppler. No TeX Live installation. A preamble that loads `tikz`, or another package that reserves PDF objects with `\pdfobj reserveobjnum`, needs texres 0.7.9: 0.7.8 dumps it, and every equation that loads the `.fmt` file then fails.

  When a program of the requested engine is not found, the backend warns once per buffer, naming the engine and the program, and the request returns `nil`. Nothing is recorded: the next request runs the program again, so an equation compiles once the program is installed.

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
- **`texres`** runs the `pdflatex` of [texres](https://github.com/leoliu0/texres), a TeX distribution in a single executable written in Rust, then `pdftocairo -svg` from [Poppler](https://poppler.freedesktop.org). It is full LaTeX, with the LaTeX engine's preamble options, and needs no TeX Live installation.

All three produce the same color- and size-independent SVG, cropped to the ink, so everything under [API](#api) works the same with each. The engine is part of the cache key, so each engine's SVGs stay cached when a caller switches to another.

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

To use texres, install it (see its README; on macOS `brew install leoliu0/texres/texres`) and Poppler, which provides `pdftocairo`, or set `latex-to-svg-backend-texres-program` and `latex-to-svg-backend-pdftocairo-program` to their paths. A front-end then passes `:engine 'texres`.

What changes with texres:

- **The same LaTeX.** `latex-to-svg-backend-preamble-base`, `-preamble-packages`, `-preamble-not-precompiled`, `-line-width`, `-precompile` and `-metadata-prefix` apply as for the LaTeX engine, and compile metadata works. texres dumps its own `.fmt` file, next to the LaTeX engine's.
- **One `pdflatex` pass.** The backend runs `texres -progname=pdflatex`, which runs one `pdflatex` pass, without texres's latexmk-style driver.
- **PDF, then SVG.** texres writes PDF, which `pdftocairo -svg -noshrink` converts; the backend crops the SVG to the ink, as `dvisvgm --exact-bbox` does. A rule that ends the ink (a fraction bar, the bar of a root) leaves the box 0.2pt wider on each side than with `dvisvgm`.
- **The ink.** The backend writes `\color[RGB]{1,2,3}` before the equation and turns that color into `currentColor`, so a formula's own `\color{black}` stays black. This needs `xcolor`, which the default preamble loads; without it, black becomes `currentColor`.
- **Speed.** Measured with the batch command under [Benchmark](#benchmark), a new equation compiled in 86–91 ms instead of LaTeX's 323–367 ms (medians), and the 20 equations queued at once in 402–460 ms instead of 1522–1700 ms.

## Benchmark

The time to compile a new equation, with each engine, for the 20 equations in [`dev/latex-to-svg-backend-benchmark.el`](dev/latex-to-svg-backend-benchmark.el) (inline and display math, `equation`, `align`, matrices, `cases`). Every run starts from an empty cache, so every equation compiles. A cached equation costs the same with every engine, because none runs: showing it again, a theme switch and a font change are all cache hits.

| | LaTeX (`latex` + `dvisvgm`, `.fmt`) | RaTeX (`render-svg`) |
| --- | ---: | ---: |
| One equation at a time, median | 313–316 ms | 6–7 ms |
| One equation at a time, fastest to slowest | 300–353 ms | 6–12 ms |
| All 20 queued at once, until the last is ready | 1321–1394 ms | 48–55 ms |
| One-time `.fmt` build | 377–396 ms | — |

*One at a time* compiles an equation, waits for it, then starts the next. *All at once* is what a front-end does when it opens a buffer; the compiles then run in parallel, which brings LaTeX to 66–70 ms per equation and RaTeX to 2–3 ms. Each figure is the range over three rounds.

The LaTeX runs used the default preamble. Loading `physics`, `stmaryrd`, `siunitx` and `mathtools` through `latex-to-svg-backend-preamble-packages` as well changed the median to 335–338 ms, the batch to 1366–1379 ms and the `.fmt` build to 517–529 ms: the `.fmt` loads the packages once, so each equation barely pays for them.

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
(latex-to-svg-backend LATEX &key callback metadata engine fallback quiet tentative rescale-by color background padding x-height)
```

`LATEX` is placed **verbatim** in the LaTeX document body, so pass valid body LaTeX — math with its delimiters (`$x$`, `\(x\)`, `\[x\]`) or a full environment (`\begin{equation}…\end{equation}`). The delimiters also decide inline vs display sizing; the backend is deliberately unaware of that distinction (a front-end that has bare bodies wraps them itself). Equation numbering, if a front-end wants it, is just a `\setcounter{equation}{N}` prepended to the body — it folds into the content hash for free.

Returns an image now when one can be produced synchronously (cache / on-disk SVG), else `nil` after scheduling an asynchronous compile. `CALLBACK` is a function of one argument, OUTCOME, and is called exactly once for every request that returned `nil`: with `nil` once the SVG is ready, so the caller can re-query (`latex-to-svg-backend` again → now returns the image) and place it, or with a plist when the request ended without a picture; see [Failed compiles](#failed-compiles-and-the-fallback-engine). An equation compiled but requested with no `X-HEIGHT` returns `nil` and calls nothing (see `X-HEIGHT` below). Concurrent requests for the same equation are coalesced onto a single compile. At most `latex-to-svg-backend-jobs` compiles run at once; further compiles wait in a queue and start, oldest first, as running ones end.

`(latex-to-svg-backend-cancel CALLBACK)` cancels the request made with `CALLBACK`, for example when a newer request for an edited equation replaces it. `CALLBACK` is compared with `eq`, so the caller makes one closure per request and keeps it. `CALLBACK` is not called, unless the request ended while `latex-to-svg-backend` ran: that call waits in a timer and still comes. A compile that no other request waits for is stopped: a queued one is taken off the queue, a running one has its process killed and its scratch directory deleted, and its slot goes to the next compile. A stopped compile records no failure, so a later request for the same `LATEX` compiles it again.

`ENGINE` is `latex` (the default, also `nil`), `ratex` or `texres`; see [Engines](#engines). Any other value signals an error. `FALLBACK` names an engine that typesets `LATEX` when `ENGINE` rejects it, and `QUIET` drops the warning a failed compile gives; see [Failed compiles](#failed-compiles-and-the-fallback-engine). `TENTATIVE` says a failure of this request is expected, as for an equation typeset at each pause while the user types it; see [Failed compiles](#failed-compiles-and-the-fallback-engine).

`RESCALE-BY` (default `1.0`) multiplies the display size of this one call on top of `latex-to-svg-backend-font-scale`. The backend has no inline/display awareness, so a front-end that wants display equations a touch larger than inline passes, say, `:rescale-by 1.1` for display and nothing for inline. It is a display-time scale only — same on-disk SVG, no recompile — and folds into the in-memory image cache key, so both sizes coexist. `METADATA` is documented under [Compile metadata](#compile-metadata-eld-sidecar) below.

`COLOR` is the tint and `BACKGROUND` the box color, both `#rrggbb` strings. `COLOR` is required whenever `X-HEIGHT` is given; `BACKGROUND` defaults to `nil` = transparent, so equations blend into the buffer. The backend resolves no color names and reads no faces: a name resolves on a frame, and only the front-end knows which frame shows its buffer, so it resolves the color there. A `COLOR` or `BACKGROUND` in any other form signals an error. `PADDING` grows the `BACKGROUND` box beyond the ink — the SVG viewport is enlarged and a filled `<rect>` baked in — and scales with the equation; `nil` / `0` crops the box to the ink. It is either a number of pt, applied to all four sides, or a list of one to four numbers read in **CSS order**:

| Spec | Sides |
| --- | --- |
| `6` or `(6)` | all four |
| `(2 6)` | vertical, horizontal |
| `(2 6 4)` | top, horizontal, bottom |
| `(2 6 4 8)` | top, right, bottom, left |

So a left gutter and nothing else is `:padding '(0 0 0 6)`. Each dimension grows by the sum of its two sides and the origin shifts by the left/top ones, so the ink stays put relative to the sides that were not padded. A malformed spec (wrong length, a non-number, a negative side) signals an error rather than silently rendering an unpadded box. Like `RESCALE-BY` they apply at display time only — same on-disk SVG, no recompile — and fold into the image cache key so variants coexist. A front-end owns any user-facing “fixed color” / “boxed equation” preference and passes it here.

`X-HEIGHT` (pixels) is the x-height of the font of the text around the equation, the height of its lowercase `x`. The front-end reads it on the frame that shows the buffer, for example as the ascent of `x` that `font-get-glyphs` gives for the `font-at` the equation, and passes it; see [Size and baseline](#size-and-baseline). Anything but `nil` or a positive number signals an error. `nil` means the buffer is shown nowhere: the backend still ensures the size-independent SVG is compiled and cached, but returns `nil` and measures nothing. The front-end re-queries once the buffer is shown, and the image is built then, from cache, with no recompile. The `latex` → `dvisvgm` **compile** never needs a frame; only building the display image does.

Call it within the target buffer: the engines read their options there, so a buffer-local value applies to that buffer's equations.

Helpers a front-end typically needs for its refresh policy:

| Function | Purpose |
| --- | --- |
| `latex-to-svg-backend-available-p` | whether this Emacs can display SVG images (built with librsvg). Without it a request compiles nothing, returns `nil` and warns once per buffer. It depends on the build, not on a frame: whether to request a render for a buffer shown only on a terminal is the front-end's decision |
| `latex-to-svg-backend-tools-available-p` | the programs of an engine on `exec-path`: `latex` + `dvisvgm`, `render-svg` with the argument `ratex`, or `texres` + `pdftocairo` with `texres`. A request does not call it: it runs the programs, and a missing one is warned about |
| `latex-to-svg-backend-image-width` | the width in pixels at which an image the backend returned is displayed: its `:width`, at `:scale` 1.0 |
| `latex-to-svg-backend-cancel` | `(latex-to-svg-backend-cancel CALLBACK)`: cancel the request made with `CALLBACK` (see above); returns non-nil when a request was cancelled |
| `latex-to-svg-backend-invalidate` | forget a cached render (delete its on-disk SVG + in-memory images, and its `.eld` sidecar) so the next call recompiles — an escape hatch for a stale/corrupt cache, and the way to retry a failed compile; an optional second argument names the engine, as for `:engine` |
| `latex-to-svg-backend-metadata` | read back compile metadata for a LaTeX body (see below), on cache hit or miss; an optional second argument names the engine |
| `latex-to-svg-backend-engine-used` | `(latex-to-svg-backend-engine-used LATEX ENGINE FALLBACK)`: the engine whose picture a request with those arguments resolves to — `ENGINE`, `FALLBACK` when `ENGINE` failed, or `nil` when neither has a picture |
| `latex-to-svg-backend-failure` | `(latex-to-svg-backend-failure LATEX ENGINE FALLBACK)`: the recorded failure a request with those arguments resolves to, the plist its callback gets — `ENGINE`'s, `FALLBACK`'s when it failed too, or `nil` when either has a picture or nothing is recorded. For a caller with no request in flight, for a tooltip or a redraw |

### Size and baseline

**Size.** The image of an equation gets `:width` W pixels at `:scale 1.0`, with W = the SVG's width × `X-HEIGHT` × `latex-to-svg-backend-font-scale` × `RESCALE-BY` / the x-height of the equation's font. So at 1.0 the equation's lowercase letters are as tall as the text's, as CSS's `font-size-adjust` matches one font to another. Fonts of the same size draw letters of different heights: JetBrains Mono's lowercase is about 0.55 of its size, Computer Modern's 0.43, so matching the font size instead would make an `n` in an equation visibly smaller than an `n` in a monospace text. Capitals and digits come out about 10% larger than a text font's, since Computer Modern's capitals are tall for its x-height. The height follows from the aspect ratio. Display equations follow the same rule; a front-end that wants them larger passes `RESCALE-BY`.

The x-height of the equation's font comes from TeX: each LaTeX compile writes `\fontdimen5` of the math italic font into the SVG, so a preamble that loads another math font (`newtxmath`, say) is followed. RaTeX always uses KaTeX's fonts, whose x-height is 0.431 em.

Nothing is measured, and the size is the same on every port. Emacs converts an SVG's pt to pixels at a resolution that differs between ports (72.27 dpi on macOS, 96 or the monitor's on X, pgtk and Windows); with `:width` that conversion does not enter. `X-HEIGHT` is in the port's pixels already, since Emacs converts a font's points at the same resolution.

**Baseline.** An inline equation's `:ascent` puts its baseline on the line's, so `$x$` and `$y$` sit on the text's baseline as letters do. Each engine records the baseline of the equation's line in the SVG, as a comment `<!--latex-to-svg-backend-baseline Y-->`: the LaTeX engine through a dvisvgm special after the equation, whose `{?y}` dvisvgm replaces with the position; texres through `\pdfsavepos`; RaTeX through an invisible strut that puts the baseline at the middle of its SVG. The `:ascent` is the share of the image above the baseline, in percent. A display equation has no baseline, since TeX sets it on a line of its own, and is centred.

Using TeX's baseline for the `:ascent` follows `org-latex-preview` in [the fork of Org mode](https://code.tecosaur.net/tec/org-mode.git) by Karthik Chikmagalur (karthink) and TEC (tecosaur), which takes the height and depth from the `preview` package; here the images are cropped to the ink, so the position comes from the page TeX shipped.

### Failed compiles and the fallback engine

When an engine rejects the formula — RaTeX cannot parse it, or LaTeX stops on an error in the document — the failure is recorded in the equation's `.eld` sidecar as `(:failed t :kind formula :engine ENGINE :message MESSAGE :line LINE :column COLUMN)`, and a later request with the same `:engine` returns `nil` without compiling. A missing program, a crash or a killed process is not the formula's fault, so it is not recorded, and the next request compiles again. A missing program is warned about once per buffer per engine and program: "The texres engine could not run `pdftocairo': program not found." The record also holds the stamp of the engine's program, as the stamp of a `.fmt` file does: its name and modification time, and for LaTeX those of the distribution's `latex.fmt` and of the `ls-R` file of each TeX tree, from the `.fmt` file the compile loaded. A request honours the record only while these files are unchanged and the program is the one the engine's option names, so an update of the engine compiles the equation again. The record belongs to the cache key, so anything that changes the key retries on its own; `latex-to-svg-backend-invalidate` deletes the record for the rest (see [Troubleshooting](#troubleshooting)).

A failure of a request passed `:tentative t` is not recorded, so a later request for the same equation compiles it again; the callback still gets the failure. Requests for the same equation share one compile, whose failure is recorded unless every one of them is tentative.

A failed compile warns once per equation per buffer, naming the buffer and linking to the log. `:quiet t` drops that warning for the call; configuration problems (a missing program, an unwritable cache, an Emacs without SVG support) still warn. Every warning names the buffer that made the request, and is shown once per buffer per cause, with no expiry: opening the file again shows it again. A buffer killed before its compile ends gets no warning. The cache collector, which no buffer requests, warns each time it fails. The backend has no option for `:quiet`: a front-end owns the user's choice and passes it, as for `:engine`. A front-end that shows the error itself passes `:quiet t` and uses the plist below.

A request that ended without a picture calls `CALLBACK` with a plist:

```elisp
(:kind formula             ; formula: the formula's fault, recorded
                           ; setup: a missing program, a crash, no SVG support; not recorded
 :engine latex             ; the engine that failed: latex, ratex or texres
 :message "Undefined control sequence."   ; one line, for a tooltip
 :line 1                   ; 1-based line in LATEX, or nil
 :column 32                ; 0-based column in that line, or nil
 :log "/…/KEY.log"         ; the saved log, or nil when there is none
 :program "dvisvgm")       ; setup only: the program not found
```

`:line` and `:column` count in `LATEX`, the string the caller passed: a front-end that puts lines in front of the equation (a `\setcounter`, say) subtracts them. They are where TeX stopped: `:line` is the N of TeX's `l.N` line, counted in `LATEX`, and `:column` is where TeX split that line. An error TeX reports outside `LATEX`, such as *Missing $ inserted* at `\end{document}`, has `:line` and `:column` nil. The LaTeX engine runs `latex` with `error_line`, `half_error_line` and `max_print_line` raised in its environment, so the log shows the whole line; texres reads them from version 0.7.9 on; texres 0.7.8 and older ignore them and cut the line to about 50 characters, so their `:column` is nil for a long line. RaTeX gives a message and no position: the position it reports counts in the formula it was given, which has no delimiters and has the macros in front.

When the request finds a failure record, or a failure ends it before `latex-to-svg-backend` returns, as a missing program or an Emacs without SVG support does, `CALLBACK` is called from a timer, so it never runs before the request returns. A cached failure, after a restart say, is the plist the failed compile gave, and `latex-to-svg-backend-failure` returns it with no request in flight.

`:fallback 'latex` typesets a formula `ENGINE` rejected with LaTeX instead, under LaTeX's own cache key, so a later request with the same `:engine` and `:fallback` returns LaTeX's picture from cache. The callbacks queued for the failed compile are called when LaTeX's compile ends: with `nil` when its SVG is ready, with LaTeX's failure when it fails too. With a fallback, the failure a callback gets is the fallback's, the last engine that tried. The same string must be valid LaTeX: a macro defined only in `latex-to-svg-backend-ratex-macros` fails in both engines. When `latex` or `dvisvgm` is missing, the backend warns as for any missing program. The first fallback picture in a buffer is announced with a message such as `3 equations in notes.md fell back to LaTeX: RaTeX could not parse them`, since those pictures are typeset in LaTeX's style (Computer Modern) and RaTeX's in KaTeX's fonts. `latex-to-svg-backend-engine-used` tells a front-end which engine drew an image, for example for a tooltip.

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

For an equation you *don't* want to track, do nothing extra: call `(latex-to-svg-backend BODY …)` with no `:metadata` and inject no `\typeout`. No sidecar is written and `(latex-to-svg-backend-metadata BODY)` returns `nil` — the whole mechanism is inert unless you opt in (and stays off entirely while `latex-to-svg-backend-metadata-prefix` is `nil`, its default). So `nil` is simply the normal answer for any un-probed equation; there is no "no number" sentinel to handle. `latex-to-svg-backend-invalidate` deletes the `.eld` with the SVG. The same file holds the record of a failed compile, `(:failed t …)` (see [Failed compiles](#failed-compiles-and-the-fallback-engine)), for which `latex-to-svg-backend-metadata` returns `nil`. `\typeout` has no visual effect, so the SVG is byte-identical to an un-probed one (only its content hash differs). Keep the emitted line short — TeX wraps log lines near column 80.

### Sketch of a front-end

```elisp
(defun my-appearance (buffer)
  "Return the :color and :x-height arguments for BUFFER, or nil."
  (when-let* ((window (get-buffer-window buffer t))
              ((display-graphic-p (window-frame window))))
    (with-selected-window window
      (list :color (apply #'format "#%02x%02x%02x"
                          ;; Round the 16-bit values: `color-rgb-to-hex'
                          ;; truncates, one step low just under a whole one.
                          (mapcar (lambda (v) (round (* v 255) 65535))
                                  (color-values
                                   (face-foreground 'default nil t))))
            ;; The ascent of `x' in the `default' face's font, in pixels.
            :x-height (let* ((name (face-font 'default))
                             (font (open-font (find-font (font-spec :name name))
                                              (aref (font-info name) 2))))
                        (aref (aref (font-get-glyphs font 0 1 "x") 0) 7))))))

(defun my-place (buffer beg end latex)   ; LATEX is valid body LaTeX
  (with-current-buffer buffer
    (if-let* ((img (apply #'latex-to-svg-backend latex (my-appearance buffer))))
        (my-overlay buffer beg end img)          ; cached
      (let ((s (copy-marker beg)) (e (copy-marker end)))
        (apply #'latex-to-svg-backend latex
               :quiet t
               :callback
               (lambda (outcome)
                 (with-current-buffer buffer
                   (if outcome
                       (my-mark-error buffer s e outcome) ; :message, :line, ...
                     (when-let* ((img (apply #'latex-to-svg-backend latex
                                             (my-appearance buffer))))
                       (my-overlay buffer s e img)))))
               (my-appearance buffer))))))
```

## Customization

`M-x customize-group RET latex-to-svg-backend` shows the options of all engines, with those of each engine in its own subgroup (`latex-to-svg-backend-latex`, `latex-to-svg-backend-ratex`, `latex-to-svg-backend-texres`). Which engine each option and command belongs to (the `latex-to-svg-backend-` prefix is left out):

| All engines | LaTeX and texres | RaTeX only |
| --- | --- | --- |
| `-cache-directory` | `-latex-program` | `-ratex-program` |
| `-cache-max-age` | `-dvisvgm-program` | `-ratex-macros` |
| `-gc-interval` | `-preamble-base` | |
| `-font-scale` | `-preamble-packages` | |
| `-jobs` | `-preamble-package-files` | |
| | `-line-width` | |
| | `-metadata-prefix` | |
| | `-precompile` | |
| `M-x …-gc`, `…-clear-cache`, `…-invalidate` | `M-x …-flush-format`, `…-invalidate-format` | |

The texres engine has two options of its own, `-texres-program` and `-pdftocairo-program`, in the subgroup `latex-to-svg-backend-texres`; `-latex-program` and `-dvisvgm-program` are the LaTeX engine's only.

There is no option for the engine: the caller chooses it per call (see [Engines](#engines)).

The functions under [API](#api) work with all three; `latex-to-svg-backend-metadata` returns `nil` for an equation RaTeX rendered.

| Variable | Default | Purpose |
| --- | --- | --- |
| `latex-to-svg-backend-latex-program` | `"latex"` | the `latex` binary |
| `latex-to-svg-backend-dvisvgm-program` | `"dvisvgm"` | the `dvisvgm` binary |
| `latex-to-svg-backend-preamble-base` | `standalone[varwidth]` + `amsmath`/`xcolor` | the document class and base packages |
| `latex-to-svg-backend-preamble-packages` | `""` | packages and macro files appended to `-preamble-base`, dumped into the `.fmt` file — see [A project's preamble](#a-projects-preamble) |
| `latex-to-svg-backend-preamble-package-files` | `nil` | files `-preamble-packages` loads, whose edits dump the `.fmt` file again and compile the equations again — see [A project's preamble](#a-projects-preamble) |
| `latex-to-svg-backend-line-width` | `nil` | max equation width (LaTeX dim); raise it (e.g. `"20cm"`) so wide numbered equations keep their number on one line — see below |
| `latex-to-svg-backend-cache-directory` | `$XDG_CACHE_HOME/emacs/latex-to-svg/` | cache root; holds `svg/` (sharded SVGs + sidecars) and `fmt/` (`.fmt` files) — see below |
| `latex-to-svg-backend-cache-max-age` | `90` | GC deletes equations untouched for this many days (`nil` = no age limit) |
| `latex-to-svg-backend-gc-interval` | `1` | minimum days between automatic GC runs (`nil` = no automatic GC) |
| `latex-to-svg-backend-font-scale` | `1.0` | equation size relative to the buffer font (1.0 = match) |
| `latex-to-svg-backend-jobs` | `nil` | maximum number of compiles to run at once (`nil` = the number of processors); further compiles wait in a queue |
| `latex-to-svg-backend-metadata-prefix` | `nil` | `nil` = off; the `\typeout` prefix enabling `.eld` compile-metadata capture (above) |
| `latex-to-svg-backend-precompile` | `t` | preamble precompilation to a `.fmt` (below) |
| `latex-to-svg-backend-ratex-program` | `"render-svg"` | RaTeX's `render-svg` binary |
| `latex-to-svg-backend-ratex-macros` | `""` | macro definitions put in front of every formula RaTeX renders |
| `latex-to-svg-backend-texres-program` | `"texres"` | the `texres` binary |
| `latex-to-svg-backend-pdftocairo-program` | `"pdftocairo"` | Poppler's `pdftocairo` binary |

### A project's preamble

A LaTeX project usually defines its own macros (`\newcommand`, `\DeclareMathOperator`, a local `.sty`) and loads its own packages, and its equations fail with the global preamble. The backend reads its options in the buffer that requests an equation, so a project sets them in its `.dir-locals.el`. The project's packages, and an `\input` of its macro files, go in `latex-to-svg-backend-preamble-packages`, which is appended to `latex-to-svg-backend-preamble-base` and dumped into a `.fmt` file of the project. List the files it loads in `latex-to-svg-backend-preamble-package-files`:

```elisp
((nil . ((latex-to-svg-backend-preamble-packages
          . "\\usepackage{physics}\n\\input{macros.tex}")
         (latex-to-svg-backend-preamble-package-files . ("macros.tex")))))
```

`latex-to-svg-backend-preamble-base` holds the document class and base packages. A project sets it only to change the class options or to remove a base package that conflicts with one it adds (`newtxmath` and `amssymb` both define `\Bbbk`).

The `.fmt` file of the project is deleted by `latex-to-svg-backend-gc` once it is unused.

`latex-to-svg-backend-appended-preamble` is an obsolete alias of `latex-to-svg-backend-preamble-packages` since 0.16.0, and `latex-to-svg-backend-preamble` of `latex-to-svg-backend-preamble-base` since 0.17.0. Both still work. `latex-to-svg-backend-preamble-macros` and `latex-to-svg-backend-preamble-macro-files` are obsolete since 0.18.0: put their macro files in `-preamble-packages` and list them in `-preamble-package-files`.

Every backslash is doubled, as in any Elisp string. `\input` looks for the file in the project root (`project-root`), or in `default-directory` outside a project: the backend writes `\makeatletter\def\input@path{{/path/to/project/}}\makeatother` before the text. A file below the root is named relative to it, as in `\input{paper/macros.tex}`. A value that defines `\input@path` itself replaces the backend's; to search one more directory, append to it instead:

```latex
\makeatletter\edef\input@path{\input@path{/other/dir/}}\makeatother
```

**Files the preamble loads** are followed when you list them in `latex-to-svg-backend-preamble-package-files`. Names are relative to the project root, as for `\input`, or absolute. The modification time of each file is in the cache key and in the stamp of the `.fmt` file, so an equation requested after an edit is compiled with the new file, and the `.fmt` file is dumped again first. An equation already shown keeps its picture until the front-end asks for it again: `M-x latex-to-svg-frontend-refresh` does. A listed file that does not exist is warned about once per buffer.

A file that is not listed is not followed: the cache key covers the options' text and the directory, not the contents of the files they load, and a `.fmt` file holds those contents as they were at the dump. After editing such a file, `C-u M-x latex-to-svg-frontend-refresh` deletes the buffer's `.fmt` file (`latex-to-svg-backend-invalidate-format`) and compiles its equations again. It does this for the current buffer only; other open files of the project need their own.

- The directory is part of the cache key, and of the `.fmt` file's key when `-preamble-base` or `-preamble-packages` is set per buffer, so two projects with the same `\input{macros.tex}` share neither SVGs nor `.fmt` files. A buffer with no buffer-local preamble uses the one `.fmt` file everyone shares.
- A directory holding one of `\ { } % # ~`, or a remote one (the compile runs locally), gets no `\input@path` and is reported once per buffer.
- `-preamble-base` and `-preamble-packages` have no `:safe` predicate, as both are LaTeX code: Emacs asks
  before applying them from a `.dir-locals.el`, and answering `!` trusts only
  that exact value, so the next edit of the string asks again. For a project
  you started or otherwise trust, list its directory, the one holding
  `.dir-locals.el`, in `safe-local-variable-directories` (Emacs 30.1+). Emacs
  then applies that `.dir-locals.el` without asking, whatever it sets:

  ```elisp
  (add-to-list 'safe-local-variable-directories
               (expand-file-name "~/papers/thesis/"))
  ```
- `-preamble-package-files` is `:safe`: the backend only reads its files'
  modification times.
- The RaTeX engine has no preamble and ignores these options. An equation that uses a project macro fails with RaTeX and, with `:fallback latex`, is typeset by LaTeX, which reads them. RaTeX's own `latex-to-svg-backend-ratex-macros` can be set per project too.

### Controlling the width of numbered equations (`latex-to-svg-backend-line-width`)

You normally never touch this, and it only concerns *numbered* equations. A numbered display puts its number flush right at the equation's max width (the `varwidth` box, default `\linewidth` ≈ 345pt) — the usual right-margin placement you see in any document. The one case where the default bites is an equation *wider* than that margin: TeX then drops the number onto a second line. If you have such equations, set `latex-to-svg-backend-line-width` to a LaTeX dimension wide enough for your widest one (e.g. `"20cm"`) and the number stays on the line. All this does is move the right margin — out for wide equations, or *in* (a smaller value, e.g. `"6cm"`) to tuck the number closer when every equation is short.

Nothing is ever clipped: math cannot line-break, so an equation wider than the box just overflows it and is cropped to its full ink either way. Setting the width too small therefore doesn't truncate anything — its only effect is to wrap the number onto a second line (the very thing you'd be avoiding), so keep it at or above your widest numbered equation. Unnumbered content ignores this setting entirely. The value folds into the cache key, so changing it re-renders.

### Cache location & garbage collection

Every unique equation compiles to a color- and size-independent SVG named by the SHA-1 of its LaTeX + preamble + style, cached under `latex-to-svg-backend-cache-directory` (default `$XDG_CACHE_HOME/emacs/latex-to-svg/`, or `~/.cache/emacs/latex-to-svg/`). The cache **persists across sessions** and is **shared across every front-end and buffer** — an equation that appears in an Org buffer and an agent's chat compiles once. Because the SVG is color- and size-independent, a theme switch or font/zoom change is a cache *hit*, never a recompile, so the cache doesn't churn the way a color-baked one does.

Lookup is two-tier: a request is served first from the **in-memory image cache** (a ready-to-display image, keyed by content + color + scale — see [Why](#why)), then from the **on-disk SVG**, and only a miss on both triggers a compile that writes a new SVG. So re-displaying equations within a session never touches disk, and the on-disk tree only grows when a genuinely new (or evicted) equation is rendered.

The cache root is organised into three subdirectories (plus a `gc-timestamp` housekeeping file):

```
$XDG_CACHE_HOME/emacs/latex-to-svg/
├── svg/           # equation SVGs, sharded 256 ways
│   └── ab/ abcd….svg  abcd….eld  abcd….log
├── fmt/           # precompiled .fmt files of the preamble
│   └── <fkey>.fmt  <fkey>.eld  <fkey>.log
├── tmp/           # one scratch directory per running compile
│   └── compile-XXXXXX/
└── gc-timestamp
```

SVGs are **sharded** into 256 buckets under `svg/`, named by the first two hex characters of the content hash (`svg/ab/abcd….svg`, with the `.eld` sidecar and any compile `.log` alongside), so no single directory accumulates every equation.

Each compile runs in its own scratch directory under `tmp/`, writes the SVG there, and moves it into `svg/` with a rename: both are under the cache directory, so a request finds either no SVG or the whole of it. The compile deletes its scratch directory when it ends.

Stale entries are pruned by an **age-based garbage collector**. Each SVG's modification time is a last-use hint, bumped whenever the equation is (re)loaded, so `latex-to-svg-backend-gc` deletes only equations untouched for `latex-to-svg-backend-cache-max-age` days (default 90); a pruned one simply recompiles when next needed. An entry with no SVG, left by a failed compile, is dated by its `.eld` failure record, else by its `.log`, and is collected the same way. A `.fmt` older than the same age is deleted with its `.eld` stamp: each compile that loads it bumps its modification time, and one still wanted is dumped again on the next compile. The stamp and log of a failed dump are dated by the stamp and collected the same way. A scratch directory older than a day, left by an Emacs that stopped during a compile, is deleted too, also when `-cache-max-age` is `nil`. GC runs automatically at most once per `latex-to-svg-backend-gc-interval` day (default 1), coordinated through an on-disk timestamp and an idle timer — so several sessions sharing the cache don't each run it, and a daemon left running for days still collects daily. Set `-gc-interval` to `nil` to disable automatic GC (you can still call it by hand), or `-cache-max-age` to `nil` to keep entries forever.

Three interactive commands manage the cache directly:

| Command | Effect |
| --- | --- |
| `latex-to-svg-backend-gc` | run the age-based prune now (returns `(DELETED . BYTES-FREED)`) |
| `latex-to-svg-backend-clear-cache` | delete **all** cached equation SVGs (with their `.eld`/`.log` siblings) and the in-memory image cache; keeps `.fmt` files |
| `latex-to-svg-backend-invalidate` | forget one equation's cached render (its SVG, `.eld`, and in-memory images) so it recompiles — an escape hatch for a stale/corrupt entry |

### Preamble precompilation (`.fmt`)

Every equation is its own tiny LaTeX document, so each compile re-reads the class and every package in the preamble (`amsmath`, `xcolor`, and whatever you add via `latex-to-svg-backend-preamble-packages`). That parsing dominates the runtime of a small equation. With `latex-to-svg-backend-precompile` (default `t`) the backend dumps the preamble **once** to a LaTeX `.fmt` file with TeX's own `\dump`, keyed by the preamble text, and every equation compile then loads it via a `%&` first line instead of re-parsing the packages — typically **25–40% faster per equation**, more with a heavier preamble.

A compile that loaded the `.fmt` file and failed is handled as any other failed compile, and the `.fmt` file stays in use. Each dump writes a stamp, `<fkey>.eld`, that names the files the `.fmt` file was made from, with their modification times: the LaTeX binary, the distribution's own `latex.fmt`, which the distribution dumps again when its kernel or its binary is updated, and the `ls-R` index of each TeX tree the dump read from, which changes when a package is installed or updated. Each compile that loads the `.fmt` file checks these files, and when one has changed (a TeX upgrade, a `tlmgr update`, another TeX first on `exec-path`), the `.fmt` file is dumped again. MiKTeX has no `ls-R`, so there a package update is not detected.

When the dump fails, the backend warns, naming the dump's log, and compiles no equation with that preamble: each would fail on the same error, and report it once per equation. The callback of each request gets a `setup` failure whose `:log` is the dump's log. The failed dump writes its stamp too, and the preamble is dumped again once a file the stamp names changes: an edit of a file listed in `-preamble-package-files`, or an update of TeX. A change to the preamble options gives a new `.fmt` file, which is dumped at the next compile. Each failed dump warns again. After an edit of a file that is not listed, `M-x latex-to-svg-backend-invalidate-format` dumps the preamble again.

`M-x latex-to-svg-backend-flush-format` is the manual escape hatch. Set `latex-to-svg-backend-precompile` to `nil` to disable it entirely.

The `%&`-loaded `.fmt` approach is borrowed from the work of Karthik Chikmagalur (karthink) and TEC (tecosaur) on fast Org math preview. It started as karthink's proof-of-concept [`org-preview`](https://github.com/karthink/org-preview) (now archived); the `.fmt`-based `org-latex-preview` it grew into lives in a [fork of Org mode](https://code.tecosaur.net/tec/org-mode.git) and is not part of upstream Org.

Preview size is computed from the font size the front-end passes; see [Size and baseline](#size-and-baseline). Earlier versions measured it per-frame with `image-size`, which proved unreliable on some ports (returning wildly different pixel sizes for the same undisplayed SVG) and made preview sizes non-deterministic — that measurement was removed in 0.2.2.

## Troubleshooting

The backend puts your LaTeX **verbatim** into a `standalone` document with a
deliberately **minimal** preamble (`amsmath` + `xcolor`). This is a design
choice, not an oversight: LaTeX has countless edge cases (extra packages,
macros, encodings), and pulling them all into the default preamble would bloat
it — every equation would compile slower, users would be forced to install a
large TeX distribution for features they never use, and the more packages we
load the higher the chance of version-based conflicts between them. So we keep
the base lean and give you `latex-to-svg-backend-preamble-packages` to add
exactly what a given input needs. It folds into the cache key, so changing it
re-renders. A few common cases:

- **`Unicode character ... not set up for use with LaTeX`** — the input
  contains a raw Unicode character the base preamble doesn't know. A frequent
  offender is a *combining* math accent such as `x̂` (an `x` followed by
  U+0302 COMBINING CIRCUMFLEX ACCENT), which agents sometimes emit instead of
  `\hat{x}`. Add the [`pdfmathaccents`](https://ctan.org/pkg/pdfmathaccents)
  package, which maps combining accents onto their math-accent commands:

  ```elisp
  (setq latex-to-svg-backend-preamble-packages "\\usepackage{pdfmathaccents}")
  ```

  More generally, any missing character can be declared with `\DeclareUnicodeCharacter`
  (from `inputenc`) or handled by loading the appropriate package.

- **A macro or environment the input uses isn't defined** (`Undefined control
  sequence`) — load the package that provides it via
  `latex-to-svg-backend-preamble-packages`, or define the macro in a file
  that `-preamble-packages` loads with `\input`.

- **A package that cannot be dumped into the `.fmt` file**: one that opens a
  file or reads `\jobname` when it loads, or keeps LuaTeX's Lua state. The
  dump fails, and no equation is compiled (see [Preamble
  precompilation](#preamble-precompilation-fmt)). Move that package to
  `latex-to-svg-backend-preamble-not-precompiled`, which is written into
  every compile after the `.fmt` file is loaded and is not dumped. List the
  files it loads in `latex-to-svg-backend-preamble-not-precompiled-files`,
  whose edits compile the equations again. Like `-preamble-packages`, it has
  no `:safe` predicate, and `\input` looks for its files in the project
  root.

If a compile fails, the backend warns with a clickable link to the LaTeX
`.log` (kept next to the cached SVG under `svg/`), which is the fastest way to
see exactly what TeX objected to. With the RaTeX engine the same link opens
RaTeX's output, which names the command it could not parse (see
[Engines](#engines) for what RaTeX does not support).

A failure caused by the formula is recorded, and the equation is not compiled
again (see [Failed compiles](#failed-compiles-and-the-fallback-engine)).
Anything that changes the cache key retries on its own: editing the equation,
`latex-to-svg-backend-preamble-base`,
`latex-to-svg-backend-preamble-packages`,
`latex-to-svg-backend-preamble-not-precompiled`, `latex-to-svg-backend-line-width`,
`latex-to-svg-backend-ratex-macros`, or a file listed in
`latex-to-svg-backend-preamble-package-files` or
`latex-to-svg-backend-preamble-not-precompiled-files`. An update of the
engine retries too: a new TeX binary or texres, a new RaTeX, and, with
`latex-to-svg-backend-precompile` on, an install or update of a TeX
package, which changes the `ls-R` file of its tree. With precompilation
off, installing a missing TeX package does not retry: regenerate the
equations in the front-end (`C-u C-u C-c C-x C-l` in `latex-to-svg`),
which calls `latex-to-svg-backend-invalidate`, or call it yourself.

### Stale equations

An equation can show an old picture after something it depends on changed.
Which fix applies depends on what changed:

- **A file your preamble loads**, such as `macros.tex`. List it in
  `latex-to-svg-backend-preamble-package-files` (see [A project's
  preamble](#a-projects-preamble)). Then an edit compiles the equations again
  on its own, and `M-x latex-to-svg-frontend-refresh` updates the equations
  already shown. A file that is not listed is not followed: after editing it,
  run `C-u M-x latex-to-svg-frontend-refresh`, which also dumps the `.fmt`
  file again.
- **Your TeX installation**, after a `tlmgr update`, an upgrade to a new TeX
  Live year, or an update from your Linux package manager. The backend
  notices it at the next compile and dumps the `.fmt` file again, so new
  equations use the updated packages. Equations already compiled keep their
  pictures: a package update rarely changes how an equation looks, and
  compiling every equation again after each update would cost more than it
  fixes. To compile them again, regenerate them (`C-u C-u C-c C-x C-l` in
  `latex-to-svg`). On MiKTeX, which has no `ls-R` index, an update of a
  package is not noticed; `M-x latex-to-svg-backend-flush-format` dumps the
  `.fmt` files again.

## Tests

```sh
emacs -batch -l ert -l tests/latex-to-svg-backend-tests.el -f ert-run-tests-batch-and-exit
```

The suite runs without a TeX toolchain or a graphical display (graphical inputs are stubbed).

## License

GPL-3.0-or-later.
