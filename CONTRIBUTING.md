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
`wirelet` GitHub-Packages PAT are documented in
`docs/development/android.md`. Android changes are verified with
`Scripts/preflight.sh --android`.

## Pre-merge verification

Continuous integration runs the Apple build/test and the lint job on every
push and pull request. The Android cross-compile is **not** part of the PR
gate — it needs a GitHub Packages token that forks can't read, so it runs
only on push to `main` and on manual dispatch. Android changes are
therefore verified locally, before merging:

```bash
Scripts/preflight.sh            # full suite: Apple + wasm + Android
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
  wrapped in `#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT`; run
  `Scripts/gate-test-support-guards.sh` after adding test files.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design rationale behind
these conventions.

## Versioning and API compatibility

Releases follow [Semantic Versioning](https://semver.org/), but **a major
version is a milestone we choose, not an automatic consequence of a break.**
`2.0.0` was the release that made a score live in the browser — a virtualized
viewer, editing, playback and audio export — and `3.0.0` was the one that gave
every score element a stable identifier. Both carried breaks, but neither was
numbered for them. The default is to not break at all: reach for a compatible
shape first, and save the major for a release that earns the number on its own.

- **Adding to a function, initializer or property?** Add the new spelling and
  leave the old one forwarding to it under
  `@available(*, deprecated, renamed: "…")`. A defaulted trailing parameter is
  usually enough, and it keeps every construction site compiling.
- **Changing what an enum case carries?** Append a new case, mark the old one
  deprecated, and keep decoding it. Never re-purpose an existing case. The
  selection identity types are the one documented exception — see below.
- **Wire formats are append-only.** A choice index, once shipped, means what it
  meant. Give the new shape the next free index and keep the old tag readable —
  `ScoreElementIDWire` grew choice 13 for a glissando this way. `1.15.0` is the
  cautionary tale in the other direction: it appended `LayoutOptionsWire`'s
  `showsLyrics` with no declared default, and although the wire stayed readable,
  the generated Kotlin constructor gained a required ninth parameter and every
  Kotlin host stopped compiling against a release meant to be compatible.
- **Deprecated API is removed at the next major**, not before, and the
  CHANGELOG entry that deprecates something says which release will drop it.
- Mark a genuinely breaking commit with `!` in its type (`feat(selection)!:`)
  and lead its CHANGELOG entry with **Breaking:**, so the next release can be
  numbered by reading the log.

### The selection and layout types are non-exhaustive by contract

`ScoreItemID`, `ScoreElementID`, `ScoreHitTarget` and `ClefAnchor` name the
things a user can click, and `LayoutElement` names the things the engine draws.
Those sets grow whenever the engine learns to engrave or select something new,
and **growing one — a new case, or a new member on an existing case's payload —
is a MINOR release, not a major.**

This is a contract rather than something the compiler enforces, because the
package has no way to enforce it. Marking an enum non-frozen, so that clients
are *required* to write `@unknown default`, needs library evolution, and a
package resolved by version is refused any target carrying `.unsafeFlags`,
which is the only spelling `-enable-library-evolution` has in a SwiftPM
manifest. So the obligation moves to the client, and it is this:

- **Treat these four as non-frozen.** A `switch` over one of them may carry
  `@unknown default`, which is legal Swift against any enum and needs nothing
  from us: it demotes the "switch must be exhaustive" error to a warning that
  names the case you have not handled, so a new kind arrives as a diagnostic
  instead of a broken build.
- **Switch exhaustively anyway where the answer has to be decided, not
  defaulted** — and accept the compile error when the set grows. That error is
  worth having. When `ScoreElementID` gained `.glissando`, the errors it raised
  in the reference host are what forced six deliberate answers: which palette
  section to offer (none), which command removes it, that cut and copy decline
  because a glissando's end is implicit, how a hidden-staff re-stamp rebuilds
  it, that a double-click opens no caret, and that the properties panel shows
  nothing. A `@unknown default` would have skipped all six in silence.
- Pattern matches bind a case's whole payload, so a payload that gains a member
  breaks them however they are spelled. That churn is part of the same
  contract.

What stays major for these types: removing or renaming a case, or changing what
an existing one means.

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
