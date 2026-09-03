# Repository guidance

This file is the canonical agent entrypoint for this repository. Claude Code,
standalone Codex, and Codex delegated from Claude must follow the same project
rules here. Host-specific files should point here instead of copying it.

## Project

`swift-sheet-music` is a Swift Package Manager library suite for parsing,
modeling, rendering, playing, and exporting engraved music notation. It
supports Apple platforms, an Android-compatible subset, and a WebAssembly
browser build.

The project is unofficial and is not affiliated with MuseScore Limited,
Muse Group, or Apple's `MusicKit` framework.

## Read the relevant documentation

- `ARCHITECTURE.md` — durable design decisions and package boundaries.
- `CONTRIBUTING.md` — development setup, coding conventions, licensing, and PR
  expectations.
- `docs/development/android.md` — Android toolchain, JNI/Wirelet, build, test,
  and troubleshooting.
- `docs/development/webassembly.md` — wasm toolchain, browser bridge, tests,
  and size gates.
- `docs/development/playback-testing.md` — playback clocks and regression
  fixture requirements.
- `docs/development/apple-audio-testing.md` — AVFoundation export and
  SoundFont test constraints.
- `docs/development/apple-example-app.md` — building the Apple example Xcode
  project (Mac + iOS), its Sounds symlink prerequisite, and the last
  verified build record.
- `docs/development/mscx-idempotency.md` — the MSCX 2-pass encode gate, what it
  detects that no other test can, and its opt-in corpus sweep.
- `docs/musescore-engraving-reference.md` — recurring findings from the
  upstream MuseScore implementation.

Read only the documents relevant to the task. Durable project knowledge belongs
in tracked documentation, not only in an agent's memory.

## Build and verification

Use the narrowest applicable command while iterating, then run every gate for
the area changed:

```bash
swift test                         # default SwiftPM test suite
Scripts/preflight.sh --apple       # Apple build, tests, lint, and format
Scripts/preflight.sh --wasm        # wasm tests, size gate, and browser package
Scripts/preflight.sh --android     # Android cross-compile, tests, and AAR
Scripts/preflight.sh               # full Apple + wasm + Android preflight
Scripts/wasm-size.sh               # WebAssembly portable-graph size gate
```

- Run `Scripts/preflight.sh --android` for Android, JNI, Wirelet, portable
  manifest, or cross-platform test changes.
- Run `Scripts/preflight.sh --wasm` for WebAssembly, portable dependencies,
  bridge exports, or `SheetMusicFoundation` changes. Exact component commands
  are in `docs/development/webassembly.md`.
- New tests use Swift Testing (`@Test`, `#expect`), not XCTest, except UI tests
  that require `XCUIApplication`.
- Tests importing Apple frameworks or Apple-only products must be excluded from
  Android and other manifest shapes without Apple-platform test support. Run
  `Scripts/gate-test-support-guards.sh` after adding such test files and review
  its diff because its heuristic can over-wrap files.

## Project invariants

- Portable targets import `SheetMusicFoundation`, never the `Foundation`
  umbrella. A single umbrella import can add ICU and break the wasm size budget.
  Apple-only targets and `SheetMusicAndroidJNI` may import `Foundation`.
- Score and MIDI models are value types (`struct` or `enum`) and `Sendable`.
  Keep cross-references in rendering passes rather than model back-pointers.
- Use the single `SheetMusicError` error surface and `throws`; do not use
  `Result` or Optional to mean failure.
- Use idiomatic Swift names. When porting a non-obvious MuseScore algorithm,
  cite the original class or function in a doc comment without copying its code
  structure.
- Keep one responsibility per file and follow the repository's SwiftLint limit.

### Parser policy

Parsers are permissive for real-world files:

- Structural invalidity that prevents a coherent score throws
  `SheetMusicError.malformedScore`.
- Unsupported or invalid embellishments are dropped; MSCX emits a
  `ScoreDiagnostic` through the diagnostic parsing APIs.
- Cosmetic values fall back silently to neutral defaults.

MusicXML does not yet expose an equivalent diagnostic channel. Apply the same
correction policy and document the silent fallback when adding one.

## Licensing boundaries

- MuseScore's GPL-3.0 C++ source is a behavioral specification only. Do not
  vendor it or copy GPL code into `Sources/`.
- GPL-3.0 fixtures under `Tests/SheetMusicTests/Resources/` must remain confined
  to the test target. Never add them to a library or executable product.
- Do not commit the local Android test score at
  `Examples/Android/app/src/main/assets/test.mscz`.

## Generated and local files

- `Examples/Apple/SheetMusicExample.xcodeproj` is generated and gitignored.
  Edit `Examples/Apple/project.yml`, then regenerate with `xcodegen`.
- Android generated JNI and Wirelet outputs are not authoritative source. Use
  the documented scripts and verify clean regeneration after schema moves.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` are point-in-time
  records; do not rewrite historical documents to match later naming changes.

## Worktrees

Local worktrees live under `.claude/worktrees/` regardless of whether Claude or
Codex is operating in them.

A fresh worktree has no `Web/sheet-music-web/node_modules`. Install them before
running a wasm preflight there:

```bash
npm install --prefix Web/sheet-music-web
```

`Scripts/preflight.sh --wasm` now checks for them up front, but installing first
saves the round trip. If npm adds a `peerDependencies` block to
`package-lock.json`, restore it — that is local npm-version normalization, not a
change that belongs in a diff.

The Apple example's `Sounds/` directory and its large SoundFont are gitignored.
When the Apple example is in scope inside a secondary worktree, run once:

```bash
Scripts/link-apple-sounds.sh
```

Do not duplicate the SoundFont across worktrees.
