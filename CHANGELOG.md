# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-08-10

### Added

- `:color`, `:background`, and `:padding` keyword arguments to
  `latex-to-svg-backend`, for per-call control of the display-time tint, an
  optional box color behind the otherwise transparent equation, and padding
  that grows that box beyond the ink (the SVG viewport is enlarged and a
  filled `<rect>` baked in; padding is in pt and scales with the equation).
  All apply post-compile (same on-disk SVG, no recompile) and fold into the
  in-memory image cache key, so tinted / boxed / padded variants of one
  equation coexist. `:color` defaults to the buffer foreground
  (theme-tracking, unchanged behavior); `:background` and `:padding` default
  to nil (transparent, cropped to the ink). The engine keeps no tint policy
  of its own beyond following the buffer face — a front-end owns the user
  preference and passes it through (resolves alberti42/latex-to-svg-backend#1).

## [0.6.1] - 2026-08-10

### Changed

- Run the `latex` → `dvisvgm` pipeline as direct `make-process` calls with
  argv lists instead of a `cd … && … && …` string passed to
  `start-process-shell-command`. Compilation no longer goes through
  `shell-file-name`, so it is independent of the user's interactive shell
  (e.g. Nu) and drops a layer of shell quoting. Each stage must exit zero
  *and* produce its expected output before the next runs.

### Fixed

- On a failed compile, persist the combined TeX log and the captured
  per-stage stdout/stderr (with terminal status, exit code, and sentinel
  event) to the cache `.log`, so failures that never reach `equation.log`
  (missing output, signals, spawn errors) are still diagnosable.

## [0.6.0] - 2026-08-08

### Added

- `latex-to-svg-backend-line-width` to widen the equation box, so wide
  numbered display equations don't wrap their equation number onto a second
  line.

### Changed

- Fold a cache-version into the content hash and drop the `.eld` `:v` tag, so
  a change to the cache format invalidates cleanly.

## [0.5.0] - 2026-08-07

### Added

- Shard the on-disk cache and add age-based garbage collection, with
  cache-maintenance commands.

### Changed

- Renamed the package `latex-to-svg` → `latex-to-svg-backend` to reflect its
  role as the shared compile backend for the `latex-to-svg` front-end stack.
  Front-ends should now depend on `latex-to-svg-backend`.
- Tidied the cache layout: default under `emacs/`, split into `svg/` and
  `fmt/` subdirectories.

### Removed

- Removed the dead no-op `latex-to-svg-flush-metrics`.

## [0.4.0] - 2026-08-01

### Added

- Precompile the preamble to a `.fmt` format file for faster compiles.

## [0.3.1] - 2026-08-01

### Added

- `:rescale-by` per-call display-size multiplier.

## [0.3.0] - 2026-08-01

### Added

- Compile-metadata sidecar alongside each cached SVG.

## [0.2.2] - 2026-08-01

### Changed

- Deterministic preview sizing; dropped the flaky `image-size` measurement.

## [0.2.1] - 2026-08-01

### Added

- `latex-to-svg-invalidate` to clear cached renders.

## [0.2.0] - 2026-08-01

### Added

- Render LaTeX verbatim and support display math via `varwidth`.

## [0.1.0] - 2026-08-01

Initial release.

### Added

- LaTeX-to-SVG rendering engine: compile LaTeX to a color-independent SVG via
  `latex → dvisvgm`, with on-disk and in-memory caching.

[0.7.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alberti42/latex-to-svg-backend/releases/tag/v0.1.0
