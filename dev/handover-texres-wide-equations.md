# Handover: texres cuts off a wide equation on the right

Status on 2026-10-29: cause found, fix tested by hand, not built.

## The problem

A display equation wider than the `varwidth` box (`\sa@width`, default
`\linewidth` ≈ 345pt, set by `latex-to-svg-backend-line-width`) loses its
right side with the texres engine. With the LaTeX engine the same equation
is whole. Seen in the front-end, in a LaTeX buffer:

```latex
\[
  g^{(1)}(\tau) = \frac{1}{2}\left(\ee^{\ii\omega_1 \tau} + \ee^{\ii\omega_2 \tau}\right) = \cos\left(\frac{\omega_1 - \omega_2}{2}\,\tau\right) \ee^{\ii \frac{\omega_1 + \omega_2}{2} \tau},
  \qquad
  V = \abs{\cos\left(\frac{\omega_1 - \omega_2}{2}\,\tau\right)}.
\]
```

The preview ended after `V = |cos((ω₁ − ω₂)/2`. Commit `1419bd0`
documents the workaround (raise `-line-width`, e.g. to `"20cm"`) in the
README's Troubleshooting.

## Cause

The equation is about 368pt wide, so TeX reports `Overfull \hbox
(23.0666pt too wide)` and sets it past the right edge of the box.

- **LaTeX engine:** a DVI file has no page box. `dvisvgm --exact-bbox`
  crops to all the ink: a 365.7pt SVG with the whole equation.
- **texres engine:** `standalone` makes the PDF page the size of its box
  (`\sa@placebox` sets `\pdfpagewidth` to `\wd\sa@box`): `pdfinfo` gives
  `Page size: 347.696 x 38.855 pts`. `pdftocairo -svg` drops what lies
  outside the page: the last glyph of its SVG is at x = 340pt. So
  `latex-to-svg-backend--crop-to-ink` has nothing past that point to
  crop to.

## The fix, tested by hand

Make texres's page wider than the box on the right only, and keep the box:
standalone adds `\sa@border@right` to the right of the box before it sets
the page size. Write this before the equation, in the texres engine's
`:prefix` (next to `latex-to-svg-backend--texres-ink`):

```latex
\makeatletter\gdef\sa@border@right{1000pt}\makeatother
```

It must be `\gdef`: the body is typeset inside standalone's box group,
and `\sa@border@right` is read after that group ends. A `\def` changed
nothing.

Result, the same equation with pdfLaTeX and `pdftocairo -svg -noshrink`:

| | page | last glyph | `--ink-box` width |
|---|---|---|---|
| now | 347.696pt | x = 340pt | 342.0pt |
| with the `\gdef` | 1341.97pt | x = 365.9pt | 365.7pt |
| LaTeX engine (`dvisvgm --exact-bbox`) | — | — | 365.7pt |

`--ink-box` crops the empty border away, so the SVG matches the LaTeX
engine's. The box keeps its width, so a numbered equation keeps its number
where it was: flush right at `\sa@width`.

I ran plain `pdflatex`, not texres, on the default preamble plus
`\newcommand\ee{\mathrm{e}}\newcommand\ii{\mathrm{i}}\newcommand\abs[1]{\left|#1\right|}`,
with the `\gdef` right after `\begin{document}`.

## Open questions for the build

1. **Cached SVGs.** The `:prefix` is not in the cache key
   (`latex-to-svg-backend--texres-cache-salt` folds in `"texres\0"` and
   the preamble), so every clipped SVG already in the cache stays clipped.
   Changing the salt (e.g. `"texres\0"` → `"texres-2\0"`) compiles every
   texres equation once more; leaving it means users run
   `latex-to-svg-backend-invalidate` on each clipped equation. Ask the
   user.
2. **How wide.** 1000pt covers an overflow up to 1000pt. A larger value
   costs nothing in a vector PDF; PDF viewers limit a page to 14400bp, and
   `pdftocairo` was not tried at that size.
3. **Left side.** Only the right overflow was seen and tested. A display
   too wide for its line starts at the left margin, so it overflows to the
   right. Whether an equation with `leqno`, or `flalign`, can overflow to
   the left was not checked; `\sa@border@left` would be the same fix there,
   and `--ink-box` already handles an origin that is not 0.
4. **A preamble without `standalone`.** `latex-to-svg-backend-preamble-base`
   can be replaced. The `\gdef` then defines an unused macro and does
   nothing else; a guard (`\@ifclassloaded{standalone}`) is optional.
5. **pdftocairo options** (`-paperw`, `-nocrop`, `-origpagesizes`) were
   not tried. The fix above does not depend on them.

## Docs to update with the fix

The texres clipping text added in `1419bd0` becomes false:

- README, "Controlling the width of numbered equations": the sentence
  "The texres engine clips: …".
- README, texres's "PDF, then SVG" bullet: the sentence "`pdftocairo`
  drops what lies outside the PDF page, …".
- README, Troubleshooting: the entry "With the texres engine, a wide
  equation is cut off on the right." Keep it only if question 1 leaves
  clipped SVGs in users' caches.
- Docstring of `latex-to-svg-backend-line-width`: the sentences from "The
  texres engine clips …".
- CHANGELOG `[Unreleased]`: replace the Fixed entry.

The front-end README (`latex-to-svg`, commit `c844107`) has the same
Troubleshooting entry, linking here; remove it in the front-end's next
release after the backend releases the fix.
