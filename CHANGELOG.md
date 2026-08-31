# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The package summary now says what the engine does ("LaTeX-to-SVG rendering
  engine with caching") instead of naming an implementation property
  ("content-addressed"), which read as jargon in the MELPA listing and did not
  convey that the package renders math at all.
- "Content-addressed" is gone from the user-facing documentation, replaced by
  what it actually means: the cache file is named after the equation's own
  content. The property is unchanged; only the wording was opaque.
- The Commentary and README now introduce the library as the current engine
  behind `agent-shell-math-renderer` and the `latex-to-svg` preview stack,
  rather than as code extracted from the former. The extraction is history
  that helps nobody installing the package; knowing which front-ends use it
  does.
- A reported condition is now re-reported if it is still occurring a day later,
  instead of resting on a warning from weeks ago. Each mark records when it
  warned and goes stale after 24 hours, in both scopes: a cache directory the
  garbage collector cannot write reports once per collection attempt rather than
  once per process, and a document left open for days is told again. The cap is
  still per site and per condition, so a persistent failure costs one line in
  `*Warnings*` per day, never one per equation.

## [0.8.2] - 2026-08-24

### Changed

- A recovered error is now reported once per *buffer* at the sites the display
  path reaches (color resolution, font measurement, the cache-use hint, the
  collected-entry race, the metadata read), rather than once per Emacs process.
  A server runs for weeks, so a single warning per process is easily missed or
  long stale, while one per opened document stays bounded -- equations within a
  buffer still share one warning. The mark is buffer-local, so it is discarded
  with the buffer, a rename cannot re-arm it, and nothing accumulates in a
  long-lived process. Sites reached from a process sentinel or the idle GC
  timer stay session-scoped: the buffer current there is unrelated to the
  equation, so marking it would misattribute the diagnosis.
- Errors the engine recovers from are now reported instead of silenced: the
  first occurrence of each kind warns (once per site and condition per
  session), so a misconfiguration is diagnosable without one warning per
  equation. No `ignore-errors` remains in the engine -- every site either lets
  the error signal, or names the specific conditions it recovers from and
  reports them.
- Cache and temporary-file cleanup no longer wraps deletions in
  `ignore-errors`. The race those guards existed for -- another session sharing
  the cache directory removing an entry first -- is already handled by the
  primitives (`delete-file` ignores `ENOENT`; recursive `delete-directory`
  tolerates concurrent removal by contract), so the guards only hid real
  failures such as an unwritable cache directory. Those now signal.
- A cache entry the filesystem refuses to let us touch (root-owned after a run
  under `sudo`, or a read-only mount) is now reported once. The mtime is only a
  garbage-collection hint, so the entry is still left to age out and recompile.
- A display that cannot resolve colors at all, and a frame whose default font
  cannot be measured, are now reported once each instead of silently falling
  back to the default color / leaving the equation unsized.
- A `.eld` metadata sidecar or GC timestamp that cannot be written or read back
  (unwritable cache directory, a file truncated by a crash mid-write) is now
  reported once. An unusable GC timestamp is also validated as a number, not
  merely as readable syntax -- one that parsed to a non-number used to signal
  later, from the idle timer.
- A LaTeX toolchain program that cannot be *started* during preamble
  precompilation -- `kpsewhich` or the LaTeX binary moved by a TeX Live upgrade
  mid-session, after the toolchain check passed -- is now reported once instead
  of being indistinguishable from "`mylatexformat` is not installed" or "the
  preamble does not dump". The engine still falls back to full compiles.

### Fixed

- A cached equation collected by *another* session's garbage collector while it
  was being displayed no longer signals `file-missing` out of the display path.
  The shared cache directory makes that window real, and it was only
  half-guarded: the mtime bump ignored every error, but the read that followed
  ignored none. Both are now covered by one handler that treats a vanished
  entry as a cache miss, so the equation simply recompiles.
- A preamble that fails to dump to a `.fmt` is no longer retried for every
  equation. The failure blocklisted nothing, so each equation paid for another
  synchronous `latex -ini` run that could not succeed; it is now abandoned for
  the session (with one warning) and the engine falls back to full compiles --
  the behaviour a dump that fails *after* succeeding already had.
- An unreadable metadata sidecar no longer costs the equation its metadata for
  good. Only a compile writes the sidecar, and the cached SVG meant no compile
  ever happened; the entry is now discarded so the next render rebuilds both
  the SVG and the sidecar (at most once per equation per session).

## [0.8.1] - 2026-08-14

### Fixed

- Saving a failed compile's log no longer prompts for a coding system. A TeX
  log echoing an unrecognized Unicode character contains bytes that neither
  `utf-8` nor `iso-latin-1` can encode, so `write-region` popped up
  *"Select one of the safe coding systems"* from a background render. The log
  is now copied byte-for-byte (`raw-text` for both read and write), and the
  metadata scan reads `equation.log` as `raw-text` too.

## [0.8.0] - 2026-08-10

### Added

- `:font-height` keyword argument to `latex-to-svg-backend`, and an optional
  `font-height` argument to `latex-to-svg-backend-display-scale` and
  `latex-to-svg-backend-appearance`. A front-end that knows the buffer's actual
  display frame measures `default-font-height` there and passes it, so sizing
  no longer depends on which frame happens to be selected.

### Changed

- Sizing no longer guesses a frame. Previously the engine picked "the selected
  frame, else any graphical frame" to measure the font height, which could
  land on an invisible child frame or a wrong frame during an async/daemon
  render. Now the height comes from `:font-height` (caller-measured) or the
  selected frame when it is graphical; there is no cross-frame search. The
  internal `latex-to-svg-backend--graphic-frame` helper is removed.
- When no font height is known (no `:font-height` and a non-graphical selected
  frame — e.g. a background/daemon render of a buffer shown in no window),
  `latex-to-svg-backend` now ensures the size-independent SVG is compiled and
  cached but returns nil instead of sizing against a guess; the caller
  re-queries once the buffer is displayed and the image is built then from
  cache, with no recompile. Correspondingly `latex-to-svg-backend-display-scale`
  returns nil (rather than a natural-size 1.0 fallback) when the height is
  unknown. **Breaking** for callers that relied on the old headless
  natural-size behavior.

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

[Unreleased]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.8.2...HEAD
[0.8.2]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/alberti42/latex-to-svg-backend/compare/v0.7.0...v0.8.0
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
