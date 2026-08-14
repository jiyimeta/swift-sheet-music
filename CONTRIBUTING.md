# Contributing to swift-sheet-music

Thanks for your interest! This is a solo-maintained project, so for
anything beyond a small fix please open an issue first — it's easier to
agree on an approach before you invest time in a pull request.

## Development setup

Requires the Swift 6.2+ toolchain (Xcode 16+ on Apple platforms).

```bash
git clone https://github.com/jiyimeta/swift-sheet-music.git
cd swift-sheet-music
swift build
swift test          # should be 100% green
```

The whole test suite runs on SwiftPM, so `swift test` is the fastest
iteration loop. `MidiExportTests` runs MuseScore's own
`midiexport_tests.cpp` fixtures through semantic-equivalence comparison.

Lint and formatting are gated in CI, so run them before pushing
(`brew install swiftlint swiftformat`):

```bash
swiftlint lint --strict --quiet            # expect no output
swiftformat Sources Tests Examples --lint  # expect "0/N require formatting"
```

`--strict` promotes warnings to errors, which is what CI enforces. Don't
pass paths to `swiftlint` — `included:` in `.swiftlint.yml` already names
them, and passing them again lints every file twice.

To have both run automatically on commit:

```bash
pre-commit install
```

That reads `.pre-commit-config.yaml` and installs a hook into the shared
`.git/hooks`, so it covers every worktree of the clone. The hooks are
`language: system`, meaning they invoke the Homebrew binaries directly
rather than managing their own — install the tools first. Note that the
formatter runs in fix mode there, so a commit that needed reformatting is
aborted once with the files rewritten; re-stage and commit again.

### Android

The Foundation-only subset cross-compiles to Android via the official
swift.org Swift Android SDK. The toolchain, SDK, NDK sysroot, and the
`wirelet` GitHub-Packages PAT are documented in `CLAUDE.md` under
"Android build". Android changes are verified with
`Scripts/preflight.sh --android`.

## Pre-merge verification

Continuous integration runs the Apple build/test and the lint job on every
push and pull request. The Android cross-compile is **not** part of the PR
gate — it needs a GitHub Packages token that forks can't read, so it runs
only on push to `main` and on manual dispatch. Android changes are
therefore verified locally, before merging:

```bash
Scripts/preflight.sh            # Apple swift test + Android
Scripts/preflight.sh --apple    # Apple / SwiftPM only (fast)
```

## Coding conventions

- **Idiomatic Swift naming.** Don't transliterate C++ names; when a rename
  is non-obvious, note the original in a doc comment (e.g.
  `/// C++: mu::engraving::MasterScore`).
- **Value types.** Score / MIDI types are `struct` / `enum`, `Sendable`,
  with no back-pointers.
- **One responsibility per file** (SwiftLint warns past 400 lines; split
  by concern when a file outgrows it).
- **Errors via `throws`** and the single `SheetMusicError` enum — no
  `Result`, no "Optional means failure".
- New tests use **Swift Testing** (`@Test` / `#expect`), not XCTest
  (except UI tests that need `XCUIApplication`).
- Tests importing an Apple framework or an Apple-only sub-library must be
  wrapped in `#if !os(Android)`; run `Scripts/gate-android-tests.sh` after
  adding test files.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design rationale behind
these conventions.

## Licensing of contributions

- Code you contribute under `Sources/` is MIT-licensed.
- **Do not** copy GPL code (e.g. the MuseScore C++ source) into `Sources/`.
  Algorithms may be reimplemented from studying the behaviour, with a
  nominative doc comment citing the source — never a transcription.
- **Do not** add the GPL-3.0 test fixtures under
  `Tests/SheetMusicTests/Resources/` to any library or executable product;
  they must stay confined to the test target.

## Pull requests

- Keep PRs focused — one logical change per PR.
- Make sure `swift test` (and `Scripts/preflight.sh` if you touched
  Android) passes.
- Write commit messages, code comments, and docs in English.
- Add a `CHANGELOG.md` entry under "Unreleased" for user-visible changes.
