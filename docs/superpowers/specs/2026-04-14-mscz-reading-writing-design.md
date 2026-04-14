# MSCZ reading + writing, URL-based API — design

Status: proposed
Date: 2026-04-14
Target libraries: `SheetMusicMSCX`, `SheetMusicCore` (error), `SheetMusic`

## Motivation

MuseScore files are distributed as `.mscz` (a ZIP archive containing one
or more `.mscx` XML files plus auxiliary resources). Today
`SheetMusicMSCX` only parses the uncompressed `.mscx`. Real-world
consumers almost always receive `.mscz` files from MuseScore Studio,
MuseScore.com downloads, or the iOS share sheet, so requiring them to
unzip out-of-band is an unnecessary friction.

At the same time, reading and writing are symmetric needs for any
round-trip workflow (import → edit → re-save). Adding a `.mscz` writer
alongside the reader in the same spec keeps the API surface coherent
and avoids a second design pass.

The MuseScore submodule (`MuseScore/src/engraving/infrastructure/mscreader.{h,cpp}`)
is used only as an **algorithmic reference** — no code is copied — per
CLAUDE.md (`MuseScore/` is GPL and dev-only; `Sources/` stays MIT).

## Non-goals

- `Score → mscx XML` encoding. No reverse decoders exist yet, and that
  is a larger independent project. The writer here only packages
  caller-supplied `.mscx` bytes into a MSCZ container.
- Reading / writing auxiliary resources inside the container:
  `score_style.mss`, `chordlist.xml`, `Thumbnails/*`, `Pictures/*`,
  `Excerpts/*.mscx`, `audio.ogg`, `audiosettings.json`,
  `viewsettings.json`, `automation.json`. The first release is
  single-main-score only; extracting/embedding these can be added
  later without breaking the proposed API (parameters have room
  for growth via defaulted arguments or a parallel `MSCZContainer`
  type).
- Copying code from `MuseScore/`. Algorithm reference only.
- Async variants. All I/O is synchronous, matching existing API.
- Streaming / partial reads.

## Architecture

```
Sources/SheetMusicMSCX/
├── MSCXParser.swift        (unchanged XML façade; +URL overload)
├── MSCZReader.swift        (new: ZIP → main mscx bytes → MSCXParser)
├── MSCZWriter.swift        (new: mscx bytes → ZIP archive)
├── Decoders/…              (unchanged)
└── XML/…                   (unchanged)

Sources/SheetMusicCore/
└── SheetMusicError.swift   (+2 new cases)

Sources/SheetMusic/
└── SheetMusic.swift        (+ loadScore(msczData:), URL overloads, saveMSCZ)
```

Dependency direction is unchanged (top-down: umbrella → MSCX → Core;
MSCX keeps its existing `ZIPFoundation` dep, currently unused).

`MSCZReader` and `MSCZWriter` are separate files — each has a single
responsibility (unzip, zip) and neither does XML parsing. The existing
`MSCXParser.parse(_: Data)` is the only XML entry point; readers
delegate to it.

## Public API

### `SheetMusicCore.SheetMusicError` (additions)

```swift
public enum SheetMusicError: Error, Sendable {
    case invalidXML(underlying: Error)
    case malformedScore(reason: String)
    case unsupportedFeature(name: String, location: String?)
    case corruptedContainer(reason: String)            // new
    case ioError(url: URL, underlying: Error)          // new
}
```

- `corruptedContainer` fires when ZIP bytes cannot be opened, the
  expected `.mscx` entry cannot be located, an entry fails to
  decompress, or (on the writer side) ZIP creation fails. `reason`
  carries a human string with filename context.
- `ioError` fires from the URL-based overloads when
  `Data(contentsOf:)` or `Data.write(to:)` throws. The original
  `Error` is preserved so consumers can downcast to
  `CocoaError`/`POSIXError` if they want.

### `SheetMusicMSCX.MSCXParser` (new overload)

```swift
public extension MSCXParser {
    /// Read `.mscx` XML bytes from a file URL and parse into a Score.
    static func parse(contentsOf url: URL) throws -> Score
}
```

Implementation: `Data(contentsOf: url)` wrapped to `ioError`, then
delegate to the existing `parse(_: Data)`.

### `SheetMusicMSCX.MSCZReader` (new)

```swift
/// Reads `.mscz` (ZIP) containers and returns the Score contained in
/// the main `.mscx` entry. Auxiliary resources inside the archive are
/// ignored in this first release.
public enum MSCZReader {
    /// Parse `.mscz` bytes into a Score.
    public static func parse(_ data: Data) throws -> Score

    /// Parse `.mscz` bytes from a file URL into a Score.
    public static func parse(contentsOf url: URL) throws -> Score
}
```

Main-file resolution (mirrors
`mu::engraving::MscReader::mainFileName` / `readScoreFile`):

1. If the archive contains an entry at `score.mscx` (exact), use it.
2. Otherwise, among all entries whose path has no `/` separator (i.e.
   sit at archive root) and end with `.mscx` (ASCII
   case-insensitive), pick the first one in the archive's native
   enumeration order.
3. If neither match yields a file, throw
   `corruptedContainer(reason: "no main .mscx in archive")`.

The main-file resolution is implemented as an internal helper, not
exposed. MuseScore additionally considers a path basename match
against the archive's own filename; since our input is a pure
`Data` blob (no filename context), that rule is skipped. Rule 2's
fallback is sufficient for every MuseScore-generated `.mscz` observed
in the test corpus and matches the behavior of `readScoreFile` when
no `mainFileName` param is set.

### `SheetMusicMSCX.MSCZWriter` (new)

```swift
/// Packages already-serialized `.mscx` XML bytes into a `.mscz`
/// (ZIP) container. Does NOT serialize a `Score` — callers provide
/// the `.mscx` bytes themselves. A high-level `write(score:)`
/// overload will be added once a `Score → XML` encoder exists.
public enum MSCZWriter {
    public static func write(
        mscxData: Data,
        mainFileName: String = "score.mscx"
    ) throws -> Data

    public static func write(
        mscxData: Data,
        to url: URL,
        mainFileName: String = "score.mscx"
    ) throws
}
```

Archive layout produced:

```
<mainFileName>           ← the provided mscxData bytes, Deflate-compressed
```

No `META-INF/container.xml`, no auxiliary resources. MuseScore's own
`MscReader::readScoreFile` does not require `container.xml` (it
resolves the main file by name/extension only — confirmed by reading
`mscreader.cpp:154–170`), so the minimal archive round-trips cleanly
through both our reader and MuseScore Studio.

Errors:

- `corruptedContainer(reason:)` if `mainFileName` is empty, contains
  `/`, or if ZIPFoundation fails to build the archive.
- `ioError` from the URL overload if `Data.write(to:)` throws.

### `SheetMusic` umbrella façade (additions)

```swift
public extension SheetMusic {
    // Existing:
    // static func loadScore(mscxData: Data) throws -> Score
    // static func exportMIDI(score: Score) throws -> Data

    static func loadScore(msczData: Data) throws -> Score
    static func loadScore(mscxURL: URL) throws -> Score
    static func loadScore(msczURL: URL) throws -> Score
    static func saveMSCZ(mscxData: Data) throws -> Data
    static func saveMSCZ(mscxData: Data, to url: URL) throws
}
```

Each delegates to the corresponding `MSCXParser` / `MSCZReader` /
`MSCZWriter` static method. The umbrella adds no logic.

## Data flow

**Reading `.mscz`:**

```
Data (mscz bytes)
  └─> MSCZReader.parse
        ├─> ZIPFoundation.Archive(data:)
        ├─> locate main entry (rule 1, fallback rule 2)
        ├─> Archive.extract(entry) → Data (mscx XML bytes)
        └─> MSCXParser.parse(_: Data) → Score
```

**Writing `.mscz`:**

```
Data (mscx XML bytes)
  └─> MSCZWriter.write
        ├─> ZIPFoundation.Archive(accessMode: .create) on empty Data
        ├─> Archive.addEntry(with: mainFileName,
        │                    type: .file,
        │                    uncompressedSize: mscxData.count,
        │                    compressionMethod: .deflate,
        │                    provider: chunked reader over mscxData)
        └─> return Archive.data
```

The ZIPFoundation in-memory writing pattern (`Archive(data:)` with
`.create`, provider closures) is standard for the library.

## Error mapping

| Situation                                           | Error                                     |
| --------------------------------------------------- | ----------------------------------------- |
| ZIP bytes unparseable                               | `corruptedContainer`                      |
| Archive has no main `.mscx`                         | `corruptedContainer`                      |
| Archive entry fails to decompress                   | `corruptedContainer`                      |
| Main mscx XML ill-formed                            | `invalidXML` (unchanged)                  |
| Main mscx XML well-formed but missing required els  | `malformedScore` (unchanged)              |
| ZIP creation failure (writer)                       | `corruptedContainer`                      |
| Invalid `mainFileName` (empty or has `/`)           | `corruptedContainer`                      |
| `Data(contentsOf:)` fails in URL overload           | `ioError`                                 |
| `Data.write(to:)` fails in URL overload             | `ioError`                                 |

## Testing

All new tests live in `Tests/SheetMusicTests/`. The test target
already depends on all four library products, so no package-manifest
changes are needed.

### Fixtures

- New fixture `Tests/SheetMusicTests/Resources/midi01.mscz`: the
  existing GPL-licensed `midi01.mscx` fixture zipped into a
  minimal single-entry archive (root path `score.mscx`). Generated
  once with `zip` on the command line; committed as a binary blob.
- `Tests/SheetMusicTests/Resources/LICENSE` appended with a note
  that `.mscz` fixtures are the same GPL-3.0 provenance as the
  `.mscx` they contain (trivial re-packaging; no new content).
- No additions to `NOTICE` or top-level `LICENSE` (scope unchanged:
  MIT `Sources/`, GPL test-only fixtures).

### New test suites

1. **`MSCZReaderTests`** in `Tests/SheetMusicTests/MSCZReaderTests.swift`.
   - `parseMatchesDirectMSCX`: load `midi01.mscz`, parse to Score,
     assert equal to parsing `midi01.mscx` directly. `Score` is
     `Equatable` (verified — every Score type conforms), so
     direct `#expect(a == b)` works; no bespoke helper needed.
   - `corruptZipThrows`: feed random non-zip bytes → expect
     `corruptedContainer`.
   - `emptyZipThrows`: build an empty `Archive` in-memory in the
     test → expect `corruptedContainer` with a `.mscx`-related
     reason.
   - `fallbackFileName`: build a Zip whose only entry is
     `renamed.mscx` at root → expect successful parse via rule 2.
   - `urlOverload`: write `midi01.mscz` bytes to a temp file,
     call `parse(contentsOf:)`, assert identical Score.
   - `urlIOErrorWrapped`: call `parse(contentsOf:)` with a URL
     that doesn't exist → expect `ioError`.

2. **`MSCZWriterTests`** in `Tests/SheetMusicTests/MSCZWriterTests.swift`.
   - `roundTripDefault`: read `midi01.mscx` bytes, write via
     `MSCZWriter.write(mscxData:)`, read the output via
     `MSCZReader.parse`, assert Score equal to direct parse.
   - `roundTripCustomName`: same but `mainFileName: "custom.mscx"`
     → still readable (exercises rule-2 fallback).
   - `urlWriteThenRead`: write to temp URL, read via
     `MSCZReader.parse(contentsOf:)`.
   - `invalidMainFileNameThrows`: empty string and `"a/b.mscx"`
     → expect `corruptedContainer`.

3. **`MSCXParserURLTests`** in
   `Tests/SheetMusicTests/MSCXParserURLTests.swift` — minimal
   coverage of the new `parse(contentsOf:)` overload (success case
   + `ioError` case). Keeps per-file test surface small and mirrors
   `MSCZReader`'s URL tests.

### Existing tests

Unchanged. No fixture renames, no error-case renames, no behavior
changes to `MSCXParser.parse(_: Data)`.

## Risk & rollback

- **ZIPFoundation dependency risk**: already pinned at
  `0.9.20` in `Package.swift` for exactly this purpose. If the
  library ever proves inadequate, the MSCZReader/Writer internals
  can be swapped to another ZIP implementation without changing the
  public API.
- **Main-file resolution wrong for exotic archives**: if a user
  reports an `.mscz` that fails to load, inspect whether MuseScore
  stamped it with a non-standard main name. Mitigation: add an
  optional `mainFileName:` parameter to `MSCZReader.parse` in a
  later release (backward compatible addition).
- **Rollback**: new code is additive only (new files, new error
  cases, new overloads). Removing the feature is `git revert` with
  no consumer breakage as long as no one has started using the new
  API — and since this is first release of `.mscz`, that is the
  case at merge time.

## Out of spec (explicit non-decisions)

- `URL` APIs using `URLSession` / network loading — out. `URL`
  overloads assume file URLs.
- Bookmarks, security-scoped access — out. Consumers on iOS
  document-picker flows resolve those themselves before handing us
  a `URL`.
- Progress reporting / cancellation — out.
- MSCZ writing that produces the full MuseScore folder layout
  (`META-INF/`, `Thumbnails/`, `Pictures/`, `score_style.mss`,
  …) — out. See Non-goals.

## Done criteria

- `swift build` succeeds.
- `swift test` remains 100% green (48 existing + ~10 new).
- `swiftlint --quiet Sources Tests` reports 0 warnings.
- `Example/` app still builds for the iOS simulator.
- README library table notes MSCZ read + write availability
  in `SheetMusicMSCX`.
