# SheetMusicZip — in-house ZIP container for Android cross-compile

Status: spec
Date: 2026-05-19
Branch: `feature/android-toolchain`
Supersedes: `docs/superpowers/plans/2026-05-19-android-zipfoundation-unblock.md`
  (Phase 1.5 ZIPFoundation fork-and-patch, abandoned)

## Goal

Replace the `weichsel/ZIPFoundation` 0.9.20 dependency with a small in-house
`SheetMusicZip` internal target that supports the narrow ZIP feature set
swift-sheet-music actually uses, while building cleanly on every platform
the package targets — including the Android cross-compile path established
in Phase 1.

The Android cross-compile path is the forcing function. Phase 1.5
established that ZIPFoundation 0.9.20 cannot be made to cross-compile to
Android without invasive consumer-side rework (`Archive(data:)` unavailable
post-PR-#380; `CZLib` `pkgConfig` host-injects Homebrew paths into Android
link). Rather than carry a fragile fork, we replace ZIPFoundation outright
with a small focused module whose scope is exactly what `.mscz` and `.mxl`
need.

## Non-goals

- ZIP64 (archives ≥ 4 GiB, ≥ 65535 entries)
- Encryption (legacy or AES)
- Multi-disk / split archives
- Compression methods other than DEFLATE (8) and STORE (0)
- Data descriptors (general-purpose bit 3 = 1) — neither read nor written
- Streaming I/O API (chunk-at-a-time read or write)
- Appending to or modifying an existing archive in place
- File-URL streaming (callers continue using `Data(contentsOf:)` then the
  in-memory path)
- A pure-Swift DEFLATE implementation (deferred to a possible future
  phase — see "Future evolution")

## Architecture

`SheetMusicZip` is an **internal** `.target` (no library product). Public
ZIP behaviour is reached through the existing `MSCZReader` / `MSCZWriter` /
`MXLReader` façades — consumers of `swift-sheet-music` see no API surface
change.

```
SheetMusicZip (internal .target, no library product)
├── Backend/
│   ├── Deflate.swift              namespace; same signature on both backends
│   ├── DeflateApple.swift         #if canImport(Compression) — COMPRESSION_ZLIB
│   └── DeflateZLib.swift          #else — system zlib, windowBits = -15
├── Container/
│   ├── CRC32.swift                Swift table impl, single implementation
│   ├── ZipEntry.swift             value type
│   ├── ZipCompressionMethod.swift enum: .stored / .deflate
│   ├── ZipReader.swift            init(data:) + read(_:) / read(path:)
│   └── ZipWriter.swift            init + add(path:data:) + finish() -> Data
├── ZipError.swift                 internal enum; consumers translate
└── Internal/
    ├── BinaryReader.swift         little-endian cursor over Data
    └── BinaryWriter.swift         appends LE primitives to Data
```

Each file stays under SwiftLint's 300-line cap. CRC32 is a single Swift
implementation (precomputed 256-entry table) — no platform branching, no
zlib link dependency for CRC.

### Backend dispatch

```
┌──────────────┐         ┌────────────────────────────────────┐
│ ZipReader /  │         │ enum Deflate                        │
│ ZipWriter    │ ──────▶ │   static func compress(_:) throws   │
│              │         │   static func decompress(_:size:)…  │
└──────────────┘         └─────────────┬──────────────────────┘
                                       │
                  #if canImport(Compression)
                                       │
              ┌────────────────────────┴────────────────────────┐
              │                                                 │
   DeflateApple.swift                                  DeflateZLib.swift
   COMPRESSION_ZLIB (raw                              import zlib
   deflate, no header,                                deflateInit2(-15)
   no checksum)                                       inflateInit2(-15)
```

The dispatch is at compile time. Apple platforms (macOS / iOS / tvOS /
watchOS) hit `DeflateApple.swift`; Linux and Android cross-compile hit
`DeflateZLib.swift` and link against the system `libz` via
`linkerSettings: [.linkedLibrary("z", .when(platforms: [.linux, .android]))]`.

### Package.swift changes

- Remove the `weichsel/ZIPFoundation` package dependency entirely.
- Add new `.target(name: "SheetMusicZip", linkerSettings: …)` with the
  `-lz` linker setting gated to `.linux` and `.android`.
- Replace `"ZIPFoundation"` with `"SheetMusicZip"` in
  `SheetMusicMSCX`, `SheetMusicMusicXML`, and `SheetMusicTests` deps.

## Internal API

### `ZipEntry`

```swift
struct ZipEntry: Equatable, Sendable {
    let path: String                 // forward-slash, UTF-8
    let uncompressedSize: UInt32
    let compressedSize: UInt32
    let crc32: UInt32
    let method: ZipCompressionMethod
    let payloadRange: Range<Int>?    // nil on the writer side until finish()
}

enum ZipCompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
}
```

Directory entries (path ending in `/`) appear in `entries` with zero-length
payloads; current consumers (`MSCZReader` / `MXLReader`) filter for
`.file`-type entries by path-suffix or explicit name, so the presence of
directory entries is harmless.

### `ZipReader`

```swift
struct ZipReader {
    init(data: Data) throws
    let entries: [String: ZipEntry]
    func contains(path: String) -> Bool
    func read(_ entry: ZipEntry) throws -> Data
    func read(path: String) throws -> Data
}
```

`init` linearly searches for the End of Central Directory record from the
tail (up to 65557 bytes back, per spec), parses the central directory in
order, and populates `entries`. `read(_:)` re-reads the local file header
to determine payload position, then either copies (`.stored`) or
decompresses (`.deflate`) the payload, validating CRC32 and size against
the central directory entry.

### `ZipWriter`

```swift
struct ZipWriter {
    init()
    mutating func add(
        path: String,
        data: Data,
        method: ZipCompressionMethod = .deflate,
    ) throws
    consuming func finish() -> Data
}
```

`add` computes CRC32 over `data`, runs DEFLATE (or copies for `.stored`),
appends a local file header + payload to an internal buffer, and records
the entry for the central directory. `finish` appends the central
directory and EOCD, then returns the full archive bytes. The
general-purpose bit 11 (UTF-8 filename) is always set; bit 3 (data
descriptor) is never used — sizes and CRC are known before the header is
written.

### `ZipError`

```swift
enum ZipError: Error {
    case notAZip                              // EOCD not found
    case unsupportedFeature(String)           // ZIP64 / encryption / unknown method
    case corrupted(String)                    // CRC mismatch, size mismatch, malformed
    case entryNotFound(String)
    case deflateFailure(String)               // backend wrap
}
```

Consumers translate `ZipError` to existing `SheetMusicError.corruptedContainer(reason:)`
at the call site so observable failure modes do not change.

### `Deflate` backend contract

```swift
enum Deflate {
    static func compress(_ input: Data) throws -> Data
    static func decompress(_ input: Data, expectedSize: Int) throws -> Data
}
```

- I/O is raw DEFLATE — no zlib header, no Adler32.
- `expectedSize` is required because Apple's `compression_decode_buffer`
  needs a pre-sized destination buffer. The ZIP central directory always
  carries `uncompressedSize`, so this is always known.
- Apple compress path sizes the destination as
  `src_size + max(64, src_size / 16)` to handle low-entropy inputs where
  raw-DEFLATE output can exceed input size; the actually used length is
  returned by `compression_encode_buffer`.

## Supported ZIP features

| Feature | Read | Write | Notes |
|---|---|---|---|
| STORE (method 0) | ✓ | ✓ | for completeness |
| DEFLATE (method 8) | ✓ | ✓ | default for `add()` |
| UTF-8 filenames | ✓ | ✓ | bit 11 always set on write |
| Multi-file archives | ✓ | ✓ | up to 65534 entries |
| File comment | read & ignore | not written | |
| Archive comment | read & ignore | not written | |
| Extra field (any) | read & skip | not written | Unicode-path / UT etc. tolerated |
| Directory entries (`path/`) | listed | not written | |
| ZIP64 | reject | n/a | central-dir size/offset `0xFFFFFFFF` ⇒ `unsupportedFeature` |
| Encryption | reject | n/a | bit 0 set or AES extra ⇒ `unsupportedFeature` |
| Data descriptor (bit 3) | reject | n/a | `unsupportedFeature` |
| Multi-disk / split | reject | n/a | disk number ≠ 0 ⇒ `unsupportedFeature` |
| Other compression methods | reject | n/a | `unsupportedFeature(method)` |

When the central directory and local file header disagree on metadata
(common with archives written by some tools), `ZipReader` trusts the
central directory for sizes / CRC and uses the local header only to locate
the payload bytes.

## Data flow

### Read (`MSCZReader.parse(data:)`)

```
Data (.mscz bytes)
  ├─→ ZipReader(data:)
  │     • EOCD tail search
  │     • central directory parse → [String: ZipEntry]
  ├─→ pick main entry:
  │     1. reader.contains("score.mscx") ? that one
  │     2. else: first entry whose path has no '/' and ends in ".mscx"
  ├─→ reader.read(entry)
  │     • parse local file header to locate payload bytes
  │     • method == .deflate ⇒ Deflate.decompress(payload, expectedSize: ...)
  │     • CRC32(decompressed) == entry.crc32 (else ZipError.corrupted)
  ├─→ MSCXParser.parse(mscxData) → Score
  └─→ if reader.contains("audiosettings.json"):
        AudioSettings.parse → merge into Score
```

### Write (`MSCZWriter.write(mscxData:)`)

```
mscxData
  ├─→ var writer = ZipWriter()
  ├─→ writer.add(path: "score.mscx", data: mscxData, method: .deflate)
  │     • crc = CRC32(mscxData)
  │     • compressed = Deflate.compress(mscxData)
  │     • write local file header + compressed payload to buffer
  ├─→ data = writer.finish()
  │     • append central directory (one record per add)
  │     • append EOCD with central dir offset/size
  └─→ .mscz Data
```

## Migration plan

1. Continue on the existing `feature/android-toolchain` worktree
   (no new worktree; per user preference and roadmap).
2. Add `SheetMusicZip` target + internal files
   (CRC32, BinaryReader/Writer, ZipEntry/CompressionMethod, Deflate{,Apple,ZLib}).
3. Implement `ZipReader`; lock in with `ZipReaderInteropTests` and `CRC32Tests`.
4. Implement `ZipWriter`; lock in with `ZipRoundTripTests` and
   `ZipWriterMuseScoreReadbackTests`.
5. Add `ZipErrorTests` and backend-dispatch tests.
6. Rewrite `MSCZReader`, `MSCZWriter`, `MXLReader`, and `MXLTestBuilder`
   on top of the `SheetMusicZip` API.
7. Update `Package.swift`: drop `ZIPFoundation` dep, wire new target into
   `SheetMusicMSCX` / `SheetMusicMusicXML` / `SheetMusicTests`, add
   `linkerSettings: [.linkedLibrary("z", .when(platforms: [.linux, .android]))]`.
8. `swift test` 100% green on macOS.
9. Android emulator: `swift test` 100% green (Phase 1 toolchain path).
10. Manual smoke: SheetMusicExampleMac — open a `.mscz`, save a `.mscz`,
    MIDI export.
11. Commit / PR for Phase 1.6.

Each step is a single-commit-shaped slice.

## Call-site translation pattern

`SheetMusicError` gains no new cases. Each consumer catches `ZipError` and
translates it to `SheetMusicError.corruptedContainer(reason:)`. Example:

```swift
// Before
let archive: Archive
do {
    archive = try Archive(data: data, accessMode: .read)
} catch {
    throw SheetMusicError.corruptedContainer(reason: "could not open ZIP: \(error)")
}

// After
let reader: ZipReader
do {
    reader = try ZipReader(data: data)
} catch let error as ZipError {
    throw SheetMusicError.corruptedContainer(reason: "could not open ZIP: \(error)")
}
```

`archive[path]` becomes `reader.contains(path:)` + `reader.read(path:)`.
Streaming `archive.extract(entry) { chunk in buffer.append(chunk) }`
becomes `reader.read(entry)` (current consumers always collect chunks
into a single buffer, so the streaming-callback shape was load-bearing
nowhere).

## Testing

### New unit tests under `Tests/SheetMusicTests/Zip/`

- `ZipRoundTripTests` — parameterized over (0 / 1 / few B / KB / few MB)
  payloads and content patterns (all-zero, all-one, low entropy, random):
  `add → finish → read → payload bytes equal`.
- `ZipReaderInteropTests` — for each `Tests/SheetMusicTests/Resources/*.mscz`
  fixture, snapshot entry list and per-entry SHA256 of extracted bytes
  matches the values produced by ZIPFoundation 0.9.20 (snapshot captured
  in step 3 of the migration plan).
- `ZipWriterMuseScoreReadbackTests` — for a hand-picked subset of fixtures,
  parse `.mscz` → re-encode via `MSCXEncoder` → re-package via `ZipWriter`
  → re-parse via `ZipReader` + `MSCXParser` → semantic equivalence with
  the original `Score`.
- `ZipErrorTests` — truncated archives, ZIP64 markers, encryption flag,
  unsupported compression method ⇒ the right `ZipError` case is thrown.
- `CRC32Tests` — RFC 1952 vectors (empty, "a", "abc", "message digest",
  0..255 bytes) plus a longer paragraph for sanity.

Swift Testing (`@Test`, `#expect`); table-driven cases use
`@Test(arguments: [...])`.

### Existing tests that must stay green

- All of `MSCZReaderTests`.
- All of `MXLReaderTests`.
- All of `MSCZWriterTests` (including any MuseScore-Studio readback case).
- All twelve `MidiExportTests` `.mscz`-input cases.

Their continued green-state is the integration-level proof that the
call-site rewrite (step 6) preserves observable behaviour.

### Cross-platform verification

- macOS / iOS Simulator: `swift test` (existing CI).
- Android emulator: Phase 1's `Scripts/run-android-tests.sh` (or
  equivalent) — full suite, including new `Zip/` tests, must be green.
- Linux: no CI added in this phase; the `system zlib + Swift container`
  code path is identical to Android's, so Linux compatibility comes for
  free in principle. Validate ad-hoc if a Linux user reports breakage.

### Backend independence

`Deflate.compress |> Deflate.decompress = identity` is tested on both the
Apple Compression backend (macOS run) and the system-zlib backend (Android
run). Explicit cross-backend interop ("Apple-encoded blob decoded by
zlib") is not tested directly — both producers output RFC 1951 raw
DEFLATE, and `ZipReader` is the integration test that proves consumability.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Android NDK `libz` ABI variance vs macOS reader expectations. | Output `.mscz` unreadable by older MuseScore. | Manual acceptance: write a `.mscz` from Android run, open in MuseScore 4 on macOS. |
| Apple `compression_encode_buffer` low-entropy expansion. | Buffer overflow / wrong-size output. | Size destination as `src + max(64, src/16)`; use returned actual length. |
| swift-android-sdk `import zlib` missing symbols. | Link errors on Android. | Limit symbol use to `deflateInit2_` / `deflate` / `deflateEnd` / `inflateInit2_` / `inflate` / `inflateEnd`. CRC32 is handwritten so `crc32` is not required. If a needed symbol is missing, fall back to a tiny vendored C shim under `Sources/CZlibShim/` (host-injection-free because we own its manifest). |
| Unknown ZIP feature in a `.mscz` fixture (ZIP64, encryption). | `ZipReaderInteropTests` fails. | Discovered at step 3 of the migration plan — well before any call-site rewrite. |
| `ZipWriter` central directory unreadable by MuseScore Studio. | Saved files unusable by end users. | Step 10 manual smoke is mandatory before declaring Phase 1.6 done. |

## Acceptance criteria

1. `swift test` 100% green on macOS.
2. `swift test` 100% green on Android emulator (Phase 1 toolchain).
3. `grep ZIPFoundation Package.swift` returns no matches.
4. SwiftLint reports zero warnings/errors on the new sources.
5. No file in `Sources/SheetMusicZip/` exceeds 300 lines.
6. A `.mscz` written by `SheetMusicZip` opens cleanly in MuseScore Studio 4
   (manual, single fixture).
7. `SheetMusicExampleMac` open / save / MIDI-export flow works manually
   on a non-trivial fixture.

## Future evolution

Once the platform-dispatched backend lands, swapping it for a pure-Swift
DEFLATE implementation later is purely additive: container code and call
sites do not change. That replacement (Option A in the Phase 1.5 / 1.6
deliberation) is an optional upgrade — Phase 1.6 is a complete,
production-ready outcome on its own.
