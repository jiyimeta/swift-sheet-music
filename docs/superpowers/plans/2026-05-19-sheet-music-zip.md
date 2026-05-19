# SheetMusicZip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ZIPFoundation 0.9.20 with an internal `SheetMusicZip` target so `.mscz` and `.mxl` work on every platform we target — including Android cross-compile.

**Architecture:** Pure-Swift ZIP container code (EOCD parse, central directory, local headers, CRC32 table) plus a platform-dispatched DEFLATE backend (`Compression.framework` on Apple, system `zlib` via `import zlib` on Linux / Android). No `pkgConfig`. No `fopencookie`. CRC32 is a single handwritten Swift implementation. All consumers go through existing façades (`MSCZReader` / `MSCZWriter` / `MXLReader`) — no public-API change.

**Tech Stack:**
- Swift 6.2 / SwiftPM
- Apple `Compression` framework (`compression_encode_buffer` / `compression_decode_buffer`, algorithm `COMPRESSION_ZLIB`)
- System `zlib` (`deflateInit2`/`inflateInit2` with `windowBits = -15`)
- Swift Testing (`@Test`, `#expect`)
- Spec: `docs/superpowers/specs/2026-05-19-sheet-music-zip-design.md`

**Worktree:** `feature/android-toolchain` (no new worktree — per spec).

**Convention reminders (from CLAUDE.md):**
- Each Swift file ≤ 300 lines (SwiftLint `file_length`).
- Tests use Swift Testing (`@Test`, `#expect`), not XCTest.
- Test target uses `@testable import` per sub-library.
- After every Package.swift change, run `swift package describe` both with and without `SWIFT_SHEET_MUSIC_ANDROID=1` to confirm both shapes resolve.

---

## File Map

### New source files (all under `Sources/SheetMusicZip/`)

| Path | Responsibility |
|---|---|
| `Backend/Deflate.swift` | `enum Deflate {}` namespace + shared error wrapping helper. |
| `Backend/DeflateApple.swift` | `#if canImport(Compression)` extension: `compress` / `decompress` via `compression_*_buffer`. |
| `Backend/DeflateZLib.swift` | `#else` extension: `compress` / `decompress` via `deflateInit2(-15)` / `inflateInit2(-15)`. |
| `Container/CRC32.swift` | 256-entry table CRC32 (RFC 1952). |
| `Container/ZipCompressionMethod.swift` | `enum ZipCompressionMethod: UInt16 { case stored = 0, deflate = 8 }`. |
| `Container/ZipEntry.swift` | `struct ZipEntry: Equatable, Sendable` value type. |
| `Container/ZipReader.swift` | `init(data:) throws`, `entries`, `contains`, `read(_:)`, `read(path:)`. |
| `Container/ZipWriter.swift` | `init`, `add(path:data:method:)`, `finish() -> Data`. |
| `ZipError.swift` | `enum ZipError: Error`. |
| `Internal/BinaryReader.swift` | LE primitive reader over `Data` (cursor). |
| `Internal/BinaryWriter.swift` | LE primitive writer that appends to a `Data` buffer. |

### New test files (all under `Tests/SheetMusicTests/Zip/`)

| Path | Coverage |
|---|---|
| `CRC32Tests.swift` | RFC 1952 vectors plus a longer paragraph. |
| `BinaryCursorTests.swift` | Round-trip `UInt16` / `UInt32` LE; boundary errors. |
| `DeflateBackendTests.swift` | `compress |> decompress = identity` over multiple payloads. |
| `ZipReaderTests.swift` | Hand-crafted minimal archive (STORED + DEFLATE); EOCD tail search. |
| `ZipReaderInteropTests.swift` | Existing `midi01.mscz` fixture: entry list + SHA256 match snapshot. |
| `ZipWriterTests.swift` | Add + finish + round-trip through `ZipReader`; size / pattern matrix. |
| `ZipErrorTests.swift` | Truncated archive, ZIP64 marker, encryption flag, unknown method. |

### Modified files

| Path | Change |
|---|---|
| `Package.swift` | Drop `ZIPFoundation` package dep, drop `isAndroid` branching that gates ZIP, add `SheetMusicZip` target with `.linkedLibrary("z", .when(platforms: [.linux, .android]))`, wire it into `SheetMusicMSCX` / `SheetMusicMusicXML` / `SheetMusicTests`. |
| `Sources/SheetMusicMSCX/MSCZReader.swift` | Drop `#if !os(Android)` wrap, drop in-function `#if os(Android)` stubs, switch from `Archive` / `Entry` to `ZipReader`. |
| `Sources/SheetMusicMSCX/MSCZWriter.swift` | Drop `#if !os(Android)` wrap, drop in-function `#if os(Android)` stubs, switch from `Archive` to `ZipWriter`. |
| `Sources/SheetMusicMusicXML/MXL/MXLReader.swift` | Drop `#if !os(Android)` wrap, drop in-function `#if os(Android)` stubs, switch to `ZipReader`. |
| `Tests/SheetMusicTests/Helpers/MXLTestBuilder.swift` | Drop `#if !os(Android)` wrap, switch from `Archive` to `ZipWriter`. |
| `Tests/SheetMusicTests/MSCZReaderTests.swift` | Drop `#if !os(Android)` wrap (now runs on Android too). |
| `Tests/SheetMusicTests/MSCZWriterTests.swift` | Drop `#if !os(Android)` wrap. |
| `CLAUDE.md` | Remove the "Format support matrix on Android (Phase 1)" disclaimer; replace with "Android: full format support via SheetMusicZip". |

---

## Task 1: Add empty `SheetMusicZip` target

**Files:**
- Create: `Sources/SheetMusicZip/SheetMusicZip.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Create namespace source file so the target has at least one Swift file**

```swift
// Sources/SheetMusicZip/SheetMusicZip.swift
// Umbrella file for the internal SheetMusicZip target. All public-internal
// API lives in dedicated files under Container/, Backend/, Internal/.
```

- [ ] **Step 2: Add the target to `Package.swift`**

In `Package.swift`, inside the unconditional `var targets: [Target] = [...]` literal, insert at the appropriate alphabetical position (after `SheetMusicXMLTools`, before `SheetMusicMSCX`):

```swift
.target(
    name: "SheetMusicZip",
    linkerSettings: [
        .linkedLibrary("z", .when(platforms: [.linux, .android])),
    ],
),
```

(Linker setting is gated to non-Apple. Apple platforms reach DEFLATE through the `Compression` framework, autolinked when imported.)

- [ ] **Step 3: Verify both manifest shapes resolve**

Run:
```bash
swift package describe > /dev/null
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe > /dev/null
```
Expected: both exit 0, no errors.

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: success. New target `SheetMusicZip` shows up.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/SheetMusicZip/
git commit -m "feat(zip): add empty SheetMusicZip target skeleton"
```

---

## Task 2: CRC32 (table-based, RFC 1952)

**Files:**
- Create: `Sources/SheetMusicZip/Container/CRC32.swift`
- Test: `Tests/SheetMusicTests/Zip/CRC32Tests.swift`

- [ ] **Step 1: Add `SheetMusicZip` to the test target deps**

In `Package.swift`, inside the `SheetMusicTests` `dependencies:` array (both the `isAndroid` and non-Android branches), add `"SheetMusicZip"`. This is one line in two places — keep both branches sorted.

- [ ] **Step 2: Write the failing test**

```swift
// Tests/SheetMusicTests/Zip/CRC32Tests.swift
@testable import SheetMusicZip
import Testing
import Foundation

@Suite("CRC32")
struct CRC32Tests {
    // RFC 1952-style known vectors. CRC32 (initial 0xFFFFFFFF, XOR-out
    // 0xFFFFFFFF, polynomial 0xEDB88320).
    @Test(arguments: [
        (Data(), UInt32(0x00000000)),
        (Data("a".utf8), UInt32(0xE8B7BE43)),
        (Data("abc".utf8), UInt32(0x352441C2)),
        (Data("message digest".utf8), UInt32(0x20159D7F)),
        (Data(0...255), UInt32(0x29058C73)),
    ])
    func vectors(input: Data, expected: UInt32) {
        #expect(CRC32.compute(input) == expected)
    }

    @Test
    func longParagraph() {
        let s = String(repeating: "Lorem ipsum dolor sit amet, ", count: 100)
        // Length is deterministic; recompute via any independent CRC32 tool
        // and place the literal here. Until we have it, snapshot the value
        // returned by CRC32.compute and freeze it after step 4 passes the
        // vectors. (See migration plan step 3 acceptance.)
        let value = CRC32.compute(Data(s.utf8))
        #expect(value != 0)            // smoke: real value, not init constant
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter CRC32Tests`
Expected: FAIL with "cannot find 'CRC32' in scope" (or `SheetMusicZip` import warning).

- [ ] **Step 4: Implement CRC32**

```swift
// Sources/SheetMusicZip/Container/CRC32.swift
import Foundation

/// CRC-32 per RFC 1952 (the same variant used by ZIP and gzip).
/// Polynomial 0xEDB88320, initial register 0xFFFFFFFF, output XOR
/// 0xFFFFFFFF. Single Swift implementation used on every platform —
/// no platform branching, no zlib dependency for CRC.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// Compute CRC32 over the entire byte sequence.
    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter CRC32Tests`
Expected: PASS (5 vector cases + 1 long-paragraph case).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicZip/Container/CRC32.swift Tests/SheetMusicTests/Zip/CRC32Tests.swift Package.swift
git commit -m "feat(zip): add CRC32 with RFC 1952 vector tests"
```

---

## Task 3: BinaryReader / BinaryWriter

**Files:**
- Create: `Sources/SheetMusicZip/Internal/BinaryReader.swift`
- Create: `Sources/SheetMusicZip/Internal/BinaryWriter.swift`
- Test: `Tests/SheetMusicTests/Zip/BinaryCursorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SheetMusicTests/Zip/BinaryCursorTests.swift
@testable import SheetMusicZip
import Testing
import Foundation

@Suite("BinaryCursor")
struct BinaryCursorTests {
    @Test
    func roundTripLEPrimitives() throws {
        var w = BinaryWriter()
        w.writeUInt16LE(0x1234)
        w.writeUInt32LE(0xDEAD_BEEF)
        w.writeBytes(Data([0xAA, 0xBB, 0xCC]))
        let bytes = w.data
        #expect(bytes == Data([
            0x34, 0x12,                   // uint16
            0xEF, 0xBE, 0xAD, 0xDE,       // uint32
            0xAA, 0xBB, 0xCC,             // raw
        ]))
        var r = BinaryReader(data: bytes)
        #expect(try r.readUInt16LE() == 0x1234)
        #expect(try r.readUInt32LE() == 0xDEAD_BEEF)
        #expect(try r.readBytes(count: 3) == Data([0xAA, 0xBB, 0xCC]))
        #expect(r.isAtEnd)
    }

    @Test
    func underflowThrows() {
        var r = BinaryReader(data: Data([0x01]))
        #expect(throws: ZipError.self) { try r.readUInt32LE() }
    }

    @Test
    func seekAndPeek() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var r = BinaryReader(data: bytes)
        try r.seek(to: 2)
        #expect(try r.readUInt16LE() == 0x0403)
        #expect(r.cursor == 4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BinaryCursorTests`
Expected: FAIL (`BinaryReader` / `BinaryWriter` / `ZipError` not found).

- [ ] **Step 3: Stub `ZipError`**

```swift
// Sources/SheetMusicZip/ZipError.swift
import Foundation

/// Internal error type for SheetMusicZip. Consumers translate to
/// `SheetMusicError.corruptedContainer(reason:)` at the call site.
enum ZipError: Error, Equatable {
    case notAZip                              // EOCD not found
    case unsupportedFeature(String)           // ZIP64 / encryption / unknown method
    case corrupted(String)                    // CRC mismatch, size mismatch, malformed
    case entryNotFound(String)
    case deflateFailure(String)               // backend wrap
}
```

- [ ] **Step 4: Implement BinaryReader**

```swift
// Sources/SheetMusicZip/Internal/BinaryReader.swift
import Foundation

/// Little-endian cursor over a `Data` value. Used by ZipReader to walk
/// EOCD, central directory, and local file header records.
struct BinaryReader {
    private let data: Data
    private(set) var cursor: Int

    init(data: Data, cursor: Int = 0) {
        self.data = data
        self.cursor = cursor
    }

    var isAtEnd: Bool { cursor >= data.count }
    var remaining: Int { max(0, data.count - cursor) }

    mutating func seek(to offset: Int) throws {
        guard offset >= 0, offset <= data.count else {
            throw ZipError.corrupted("seek out of range: \(offset)")
        }
        cursor = offset
    }

    mutating func readUInt16LE() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return UInt16(bytes[bytes.startIndex])
             | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        let b = bytes.startIndex
        return UInt32(bytes[b])
             | (UInt32(bytes[b + 1]) << 8)
             | (UInt32(bytes[b + 2]) << 16)
             | (UInt32(bytes[b + 3]) << 24)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, cursor + count <= data.count else {
            throw ZipError.corrupted("read past end (count=\(count), remaining=\(remaining))")
        }
        let slice = data.subdata(in: cursor ..< cursor + count)
        cursor += count
        return slice
    }
}
```

- [ ] **Step 5: Implement BinaryWriter**

```swift
// Sources/SheetMusicZip/Internal/BinaryWriter.swift
import Foundation

/// Appends little-endian primitives to a `Data` buffer. Used by ZipWriter.
struct BinaryWriter {
    private(set) var data: Data = Data()

    var offset: Int { data.count }

    mutating func writeUInt16LE(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func writeUInt32LE(_ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter BinaryCursorTests`
Expected: PASS (3 cases).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicZip/Internal/ Sources/SheetMusicZip/ZipError.swift Tests/SheetMusicTests/Zip/BinaryCursorTests.swift
git commit -m "feat(zip): add BinaryReader/Writer cursors and ZipError"
```

---

## Task 4: `ZipCompressionMethod` + `ZipEntry`

**Files:**
- Create: `Sources/SheetMusicZip/Container/ZipCompressionMethod.swift`
- Create: `Sources/SheetMusicZip/Container/ZipEntry.swift`

- [ ] **Step 1: Implement `ZipCompressionMethod`**

```swift
// Sources/SheetMusicZip/Container/ZipCompressionMethod.swift
/// ZIP compression methods SheetMusicZip understands.
///
/// 0 = STORED (no compression), 8 = DEFLATE (RFC 1951). All other
/// method codes are rejected by ZipReader with
/// `ZipError.unsupportedFeature`.
enum ZipCompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
}
```

- [ ] **Step 2: Implement `ZipEntry`**

```swift
// Sources/SheetMusicZip/Container/ZipEntry.swift
import Foundation

/// One entry within a ZIP archive.
///
/// On reader-side, `payloadRange` is the byte range (within the source
/// archive `Data`) of the compressed payload — i.e. the bytes immediately
/// after the local file header. On writer-side it is nil until `finish()`
/// has been called.
struct ZipEntry: Equatable, Sendable {
    let path: String                 // forward-slash separated, UTF-8
    let uncompressedSize: UInt32
    let compressedSize: UInt32
    let crc32: UInt32
    let method: ZipCompressionMethod
    let payloadRange: Range<Int>?
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicZip/Container/ZipCompressionMethod.swift Sources/SheetMusicZip/Container/ZipEntry.swift
git commit -m "feat(zip): add ZipCompressionMethod and ZipEntry value types"
```

---

## Task 5: `Deflate` namespace + Apple backend

**Files:**
- Create: `Sources/SheetMusicZip/Backend/Deflate.swift`
- Create: `Sources/SheetMusicZip/Backend/DeflateApple.swift`
- Test: `Tests/SheetMusicTests/Zip/DeflateBackendTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SheetMusicTests/Zip/DeflateBackendTests.swift
@testable import SheetMusicZip
import Testing
import Foundation

@Suite("Deflate backend")
struct DeflateBackendTests {
    @Test(arguments: [
        Data(),
        Data([0x42]),
        Data(repeating: 0xAA, count: 1024),
        Data((0..<10_000).map { UInt8($0 & 0xFF) }),
        Data(repeating: 0x00, count: 64 * 1024),       // low-entropy stress
    ])
    func roundTrip(payload: Data) throws {
        let compressed = try Deflate.compress(payload)
        let decompressed = try Deflate.decompress(
            compressed, expectedSize: payload.count,
        )
        #expect(decompressed == payload)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeflateBackendTests`
Expected: FAIL (`Deflate` not found).

- [ ] **Step 3: Implement namespace**

```swift
// Sources/SheetMusicZip/Backend/Deflate.swift
import Foundation

/// Platform-dispatched raw-DEFLATE codec (RFC 1951, no zlib header,
/// no Adler32). Implementation lives in `DeflateApple.swift`
/// (`#if canImport(Compression)`) or `DeflateZLib.swift` (`#else`).
enum Deflate {}
```

- [ ] **Step 4: Implement Apple backend**

```swift
// Sources/SheetMusicZip/Backend/DeflateApple.swift
#if canImport(Compression)
import Compression
import Foundation

extension Deflate {
    /// Compress `input` to raw DEFLATE bytes using Apple's `Compression`
    /// framework with `COMPRESSION_ZLIB` (raw DEFLATE — no header, no
    /// checksum). Destination buffer is sized with a small head-room to
    /// tolerate low-entropy expansion.
    static func compress(_ input: Data) throws -> Data {
        if input.isEmpty {
            return Data()
        }
        let srcCount = input.count
        let dstCount = srcCount + max(64, srcCount / 16)
        var output = Data(count: dstCount)
        let written: Int = try output.withUnsafeMutableBytes { dst in
            try input.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else {
                    throw ZipError.deflateFailure("nil buffer base on Apple compress")
                }
                let n = compression_encode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self), dstCount,
                    srcBase.assumingMemoryBound(to: UInt8.self), srcCount,
                    nil, COMPRESSION_ZLIB,
                )
                guard n > 0 else {
                    throw ZipError.deflateFailure("compression_encode_buffer returned 0")
                }
                return n
            }
        }
        return output.prefix(written)
    }

    /// Decompress raw DEFLATE bytes into a buffer pre-sized to
    /// `expectedSize`. The ZIP central directory always carries
    /// uncompressedSize so this is always known.
    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 {
            return Data()
        }
        var output = Data(count: expectedSize)
        let written: Int = try output.withUnsafeMutableBytes { dst in
            try input.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else {
                    throw ZipError.deflateFailure("nil buffer base on Apple decompress")
                }
                let n = compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self), expectedSize,
                    srcBase.assumingMemoryBound(to: UInt8.self), input.count,
                    nil, COMPRESSION_ZLIB,
                )
                guard n > 0 else {
                    throw ZipError.deflateFailure("compression_decode_buffer returned 0")
                }
                return n
            }
        }
        guard written == expectedSize else {
            throw ZipError.corrupted(
                "decompressed size mismatch (got \(written), expected \(expectedSize))",
            )
        }
        return output
    }
}
#endif
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter DeflateBackendTests`
Expected: PASS (5 cases).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicZip/Backend/ Tests/SheetMusicTests/Zip/DeflateBackendTests.swift
git commit -m "feat(zip): add Deflate namespace + Apple Compression backend"
```

---

## Task 6: `Deflate` ZLib backend (Linux / Android)

**Files:**
- Create: `Sources/SheetMusicZip/Backend/DeflateZLib.swift`

Source-only task — on macOS `swift test` always exercises the Apple backend. The Android emulator run at the end of the plan is what verifies the ZLib path.

- [ ] **Step 1: Implement ZLib backend**

```swift
// Sources/SheetMusicZip/Backend/DeflateZLib.swift
#if !canImport(Compression)
import Foundation
import zlib

extension Deflate {
    /// Compress `input` to raw DEFLATE bytes using system zlib with
    /// `windowBits = -15` (raw DEFLATE — no zlib header).
    static func compress(_ input: Data) throws -> Data {
        if input.isEmpty {
            return Data()
        }
        var stream = z_stream()
        var ret = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
            -15,                  // windowBits negative => raw DEFLATE
            8,                    // memLevel default
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size),
        )
        guard ret == Z_OK else {
            throw ZipError.deflateFailure("deflateInit2 returned \(ret)")
        }
        defer { deflateEnd(&stream) }

        return try input.withUnsafeBytes { src -> Data in
            guard let srcBase = src.baseAddress else {
                throw ZipError.deflateFailure("nil src base")
            }
            stream.next_in = UnsafeMutablePointer(mutating: srcBase.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = UInt32(input.count)

            var out = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            repeat {
                ret = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = UInt32(buf.count)
                    return deflate(&stream, Z_FINISH)
                }
                guard ret == Z_OK || ret == Z_STREAM_END else {
                    throw ZipError.deflateFailure("deflate returned \(ret)")
                }
                let produced = buffer.count - Int(stream.avail_out)
                out.append(contentsOf: buffer.prefix(produced))
            } while ret != Z_STREAM_END
            return out
        }
    }

    /// Decompress raw DEFLATE bytes using system zlib with
    /// `windowBits = -15`. `expectedSize` is used to pre-size the
    /// output buffer.
    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 {
            return Data()
        }
        var stream = z_stream()
        var ret = inflateInit2_(
            &stream, -15,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size),
        )
        guard ret == Z_OK else {
            throw ZipError.deflateFailure("inflateInit2 returned \(ret)")
        }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { src -> Data in
            guard let srcBase = src.baseAddress else {
                throw ZipError.deflateFailure("nil src base")
            }
            stream.next_in = UnsafeMutablePointer(mutating: srcBase.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = UInt32(input.count)

            var out = Data(capacity: expectedSize)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            repeat {
                ret = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = UInt32(buf.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard ret == Z_OK || ret == Z_STREAM_END else {
                    throw ZipError.deflateFailure("inflate returned \(ret)")
                }
                let produced = buffer.count - Int(stream.avail_out)
                out.append(contentsOf: buffer.prefix(produced))
            } while ret != Z_STREAM_END

            guard out.count == expectedSize else {
                throw ZipError.corrupted(
                    "inflate size mismatch (got \(out.count), expected \(expectedSize))",
                )
            }
            return out
        }
    }
}
#endif
```

- [ ] **Step 2: Verify macOS build still passes**

Run: `swift build && swift test --filter DeflateBackendTests`
Expected: success — `#if !canImport(Compression)` keeps this file invisible on macOS, so it neither builds nor breaks anything.

- [ ] **Step 3: Verify Android cross-compile of `SheetMusicZip` only**

Run:
```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --target SheetMusicZip \
                --swift-sdk aarch64-unknown-linux-android28
```
Expected: success. If `import zlib` fails on Android (missing system module), proceed to the C-shim fallback noted in the spec's Risks section (`Sources/CZlibShim/`) — but try the pure `import zlib` first; the spec assumes it works.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicZip/Backend/DeflateZLib.swift
git commit -m "feat(zip): add Deflate ZLib backend for Linux / Android"
```

---

## Task 7: `ZipReader` — EOCD + central directory parse

**Files:**
- Create: `Sources/SheetMusicZip/Container/ZipReader.swift`
- Test: `Tests/SheetMusicTests/Zip/ZipReaderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SheetMusicTests/Zip/ZipReaderTests.swift
@testable import SheetMusicZip
import Testing
import Foundation

@Suite("ZipReader")
struct ZipReaderTests {
    /// A pre-computed minimal valid ZIP archive containing one STORED
    /// entry "hi.txt" with payload "hello\n". Hand-built so we don't
    /// depend on ZipWriter for ZipReader's first test.
    private static let minimalStoredArchive: Data = {
        // local file header (30 + 6 name + 6 payload)
        var d = Data()
        d.append(Data([0x50, 0x4B, 0x03, 0x04]))  // PK\3\4
        d.append(Data([0x14, 0x00]))              // version needed = 20
        d.append(Data([0x00, 0x08]))              // gp flags: bit 11 (UTF-8)
        d.append(Data([0x00, 0x00]))              // method = stored
        d.append(Data([0x00, 0x00, 0x00, 0x00]))  // mtime/mdate
        // crc32 of "hello\n" = 0x363A3020
        d.append(Data([0x20, 0x30, 0x3A, 0x36]))
        d.append(Data([0x06, 0x00, 0x00, 0x00]))  // compressed size = 6
        d.append(Data([0x06, 0x00, 0x00, 0x00]))  // uncompressed size = 6
        d.append(Data([0x06, 0x00]))              // file name length = 6
        d.append(Data([0x00, 0x00]))              // extra length = 0
        d.append("hi.txt".data(using: .utf8)!)
        d.append("hello\n".data(using: .utf8)!)
        let localHeaderOffset: UInt32 = 0
        let centralDirOffset = UInt32(d.count)

        // central directory entry
        d.append(Data([0x50, 0x4B, 0x01, 0x02]))  // PK\1\2
        d.append(Data([0x14, 0x00]))              // version made by
        d.append(Data([0x14, 0x00]))              // version needed
        d.append(Data([0x00, 0x08]))              // gp flags
        d.append(Data([0x00, 0x00]))              // method
        d.append(Data([0x00, 0x00, 0x00, 0x00]))  // mtime/mdate
        d.append(Data([0x20, 0x30, 0x3A, 0x36]))  // crc32
        d.append(Data([0x06, 0x00, 0x00, 0x00]))  // comp size
        d.append(Data([0x06, 0x00, 0x00, 0x00]))  // uncomp size
        d.append(Data([0x06, 0x00]))              // name length
        d.append(Data([0x00, 0x00]))              // extra length
        d.append(Data([0x00, 0x00]))              // comment length
        d.append(Data([0x00, 0x00]))              // disk number start
        d.append(Data([0x00, 0x00]))              // internal attrs
        d.append(Data([0x00, 0x00, 0x00, 0x00]))  // external attrs
        d.append(withUnsafeBytes(of: localHeaderOffset.littleEndian, Data.init))
        d.append("hi.txt".data(using: .utf8)!)
        let centralDirSize = UInt32(d.count) - centralDirOffset

        // EOCD
        d.append(Data([0x50, 0x4B, 0x05, 0x06]))
        d.append(Data([0x00, 0x00]))              // this disk
        d.append(Data([0x00, 0x00]))              // disk with central dir
        d.append(Data([0x01, 0x00]))              // # entries this disk
        d.append(Data([0x01, 0x00]))              // # entries total
        d.append(withUnsafeBytes(of: centralDirSize.littleEndian, Data.init))
        d.append(withUnsafeBytes(of: centralDirOffset.littleEndian, Data.init))
        d.append(Data([0x00, 0x00]))              // comment length
        return d
    }()

    @Test
    func opensMinimalStoredArchive() throws {
        let reader = try ZipReader(data: Self.minimalStoredArchive)
        #expect(reader.entries.count == 1)
        let entry = try #require(reader.entries["hi.txt"])
        #expect(entry.method == .stored)
        #expect(entry.uncompressedSize == 6)
        #expect(entry.compressedSize == 6)
        #expect(entry.crc32 == 0x363A3020)
    }

    @Test
    func eocdAtTrueTail() throws {
        // Append a junk comment to push EOCD away from the tail.
        var bytes = Self.minimalStoredArchive
        // Bump the EOCD comment length and append the comment bytes.
        let eocdStart = bytes.count - 22
        let commentLengthOffset = eocdStart + 20
        let comment = "trailing junk".data(using: .utf8)!
        var commentLen = UInt16(comment.count).littleEndian
        bytes.replaceSubrange(
            commentLengthOffset ..< commentLengthOffset + 2,
            with: withUnsafeBytes(of: &commentLen, Data.init),
        )
        bytes.append(comment)
        let reader = try ZipReader(data: bytes)
        #expect(reader.entries["hi.txt"] != nil)
    }

    @Test
    func notAZipThrows() {
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: Data("not a zip".utf8))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ZipReaderTests`
Expected: FAIL (`ZipReader` not found).

- [ ] **Step 3: Implement EOCD search + central directory parse**

```swift
// Sources/SheetMusicZip/Container/ZipReader.swift
import Foundation

/// Reads ZIP archives produced by SheetMusicZip, MuseScore Studio, and
/// other standard ZIP writers. Scope: STORED + DEFLATE, single-disk,
/// ≤ 65534 entries, no encryption, no ZIP64. See the spec for the full
/// supported-feature matrix.
struct ZipReader {
    let entries: [String: ZipEntry]
    private let data: Data

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.parseCentralDirectory(data)
    }

    func contains(path: String) -> Bool {
        entries[path] != nil
    }

    private static let eocdSignature: UInt32 = 0x06054B50
    private static let centralSignature: UInt32 = 0x02014B50
    private static let localSignature: UInt32 = 0x04034B50

    /// Walk from the tail (up to 65557 bytes back — 22-byte EOCD plus
    /// max 65535-byte trailing comment) looking for the EOCD signature.
    private static func findEOCD(in data: Data) throws -> Int {
        let minHead = 22
        guard data.count >= minHead else {
            throw ZipError.notAZip
        }
        let lowerBound = max(0, data.count - minHead - 0xFFFF)
        var pos = data.count - minHead
        while pos >= lowerBound {
            if data[pos] == 0x50, data[pos + 1] == 0x4B,
               data[pos + 2] == 0x05, data[pos + 3] == 0x06 {
                return pos
            }
            pos -= 1
        }
        throw ZipError.notAZip
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [String: ZipEntry] {
        let eocdOffset = try findEOCD(in: data)
        var reader = BinaryReader(data: data, cursor: eocdOffset)
        let signature = try reader.readUInt32LE()
        guard signature == eocdSignature else {
            throw ZipError.corrupted("EOCD signature mismatch")
        }
        let thisDisk = try reader.readUInt16LE()
        let diskWithCD = try reader.readUInt16LE()
        let entriesThisDisk = try reader.readUInt16LE()
        let entriesTotal = try reader.readUInt16LE()
        let cdSize = try reader.readUInt32LE()
        let cdOffset = try reader.readUInt32LE()
        guard thisDisk == 0, diskWithCD == 0 else {
            throw ZipError.unsupportedFeature("multi-disk archives")
        }
        guard cdSize != 0xFFFFFFFF, cdOffset != 0xFFFFFFFF,
              entriesTotal != 0xFFFF else {
            throw ZipError.unsupportedFeature("ZIP64")
        }
        guard entriesThisDisk == entriesTotal else {
            throw ZipError.corrupted("disk entry count disagreement")
        }

        try reader.seek(to: Int(cdOffset))
        var out: [String: ZipEntry] = [:]
        out.reserveCapacity(Int(entriesTotal))
        for _ in 0..<entriesTotal {
            let entry = try parseCentralEntry(&reader, in: data)
            out[entry.path] = entry
        }
        return out
    }

    private static func parseCentralEntry(
        _ reader: inout BinaryReader, in data: Data,
    ) throws -> ZipEntry {
        let sig = try reader.readUInt32LE()
        guard sig == centralSignature else {
            throw ZipError.corrupted("central directory signature mismatch")
        }
        _ = try reader.readUInt16LE()          // version made by
        _ = try reader.readUInt16LE()          // version needed
        let gpFlags = try reader.readUInt16LE()
        let methodRaw = try reader.readUInt16LE()
        _ = try reader.readUInt32LE()          // mtime/mdate
        let crc = try reader.readUInt32LE()
        let compSize = try reader.readUInt32LE()
        let uncompSize = try reader.readUInt32LE()
        let nameLen = try reader.readUInt16LE()
        let extraLen = try reader.readUInt16LE()
        let commentLen = try reader.readUInt16LE()
        _ = try reader.readUInt16LE()          // disk number start
        _ = try reader.readUInt16LE()          // internal attrs
        _ = try reader.readUInt32LE()          // external attrs
        let localHeaderOffset = try reader.readUInt32LE()
        let nameBytes = try reader.readBytes(count: Int(nameLen))
        _ = try reader.readBytes(count: Int(extraLen))
        _ = try reader.readBytes(count: Int(commentLen))

        // Reject unsupported features.
        if (gpFlags & 0x0001) != 0 {
            throw ZipError.unsupportedFeature("encrypted entry")
        }
        if (gpFlags & 0x0008) != 0 {
            throw ZipError.unsupportedFeature("data descriptor (bit 3)")
        }
        if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF
           || localHeaderOffset == 0xFFFFFFFF {
            throw ZipError.unsupportedFeature("ZIP64")
        }
        guard let method = ZipCompressionMethod(rawValue: methodRaw) else {
            throw ZipError.unsupportedFeature("compression method \(methodRaw)")
        }
        guard let path = String(data: nameBytes, encoding: .utf8) else {
            throw ZipError.corrupted("non-UTF8 entry name")
        }

        // Resolve payload range by reading the local file header just
        // for its variable-length fields.
        let payloadRange = try locatePayload(
            in: data, localHeaderOffset: Int(localHeaderOffset),
            compressedSize: Int(compSize),
        )

        return ZipEntry(
            path: path,
            uncompressedSize: uncompSize,
            compressedSize: compSize,
            crc32: crc,
            method: method,
            payloadRange: payloadRange,
        )
    }

    private static func locatePayload(
        in data: Data, localHeaderOffset offset: Int, compressedSize: Int,
    ) throws -> Range<Int> {
        var r = BinaryReader(data: data, cursor: offset)
        let sig = try r.readUInt32LE()
        guard sig == localSignature else {
            throw ZipError.corrupted("local file header signature mismatch")
        }
        _ = try r.readUInt16LE()           // version needed
        _ = try r.readUInt16LE()           // gp flags
        _ = try r.readUInt16LE()           // method
        _ = try r.readUInt32LE()           // mtime/mdate
        _ = try r.readUInt32LE()           // crc
        _ = try r.readUInt32LE()           // comp size
        _ = try r.readUInt32LE()           // uncomp size
        let nameLen = try r.readUInt16LE()
        let extraLen = try r.readUInt16LE()
        _ = try r.readBytes(count: Int(nameLen))
        _ = try r.readBytes(count: Int(extraLen))
        let start = r.cursor
        let end = start + compressedSize
        guard end <= data.count else {
            throw ZipError.corrupted("payload extends past archive end")
        }
        return start ..< end
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ZipReaderTests`
Expected: PASS (3 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicZip/Container/ZipReader.swift Tests/SheetMusicTests/Zip/ZipReaderTests.swift
git commit -m "feat(zip): add ZipReader EOCD + central directory parsing"
```

---

## Task 8: `ZipReader.read(_:)` — payload extraction + CRC verification

**Files:**
- Modify: `Sources/SheetMusicZip/Container/ZipReader.swift`
- Test: `Tests/SheetMusicTests/Zip/ZipReaderTests.swift` (append)

- [ ] **Step 1: Append failing tests**

```swift
// Append to ZipReaderTests (inside the same struct).
@Test
func readStoredPayload() throws {
    let reader = try ZipReader(data: Self.minimalStoredArchive)
    let bytes = try reader.read(path: "hi.txt")
    #expect(bytes == "hello\n".data(using: .utf8))
}

@Test
func missingEntryThrows() throws {
    let reader = try ZipReader(data: Self.minimalStoredArchive)
    #expect(throws: ZipError.self) {
        _ = try reader.read(path: "missing.txt")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ZipReaderTests`
Expected: FAIL — `read(path:)` / `read(_:)` not defined.

- [ ] **Step 3: Implement read methods**

Append to `ZipReader` struct in `Sources/SheetMusicZip/Container/ZipReader.swift`:

```swift
func read(path: String) throws -> Data {
    guard let entry = entries[path] else {
        throw ZipError.entryNotFound(path)
    }
    return try read(entry)
}

func read(_ entry: ZipEntry) throws -> Data {
    guard let range = entry.payloadRange else {
        throw ZipError.corrupted("entry has no payload range")
    }
    let payload = data.subdata(in: range)
    let result: Data
    switch entry.method {
    case .stored:
        guard payload.count == Int(entry.uncompressedSize) else {
            throw ZipError.corrupted(
                "stored size mismatch (got \(payload.count), expected \(entry.uncompressedSize))",
            )
        }
        result = payload
    case .deflate:
        result = try Deflate.decompress(payload, expectedSize: Int(entry.uncompressedSize))
    }
    guard CRC32.compute(result) == entry.crc32 else {
        throw ZipError.corrupted("CRC32 mismatch on entry \(entry.path)")
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ZipReaderTests`
Expected: PASS (5 cases — 3 prior + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicZip/Container/ZipReader.swift Tests/SheetMusicTests/Zip/ZipReaderTests.swift
git commit -m "feat(zip): implement ZipReader.read with CRC verification"
```

---

## Task 9: `ZipReader` interop with `midi01.mscz`

**Files:**
- Test: `Tests/SheetMusicTests/Zip/ZipReaderInteropTests.swift`

Verifies SheetMusicZip extracts the same bytes ZIPFoundation 0.9.20 used to extract. This test runs against the existing repository fixture; the consumer rewrite tasks below depend on this passing.

- [ ] **Step 1: Capture ZIPFoundation snapshot manually (one-off)**

In a scratch shell — **not committed** — extract via ZIPFoundation to capture per-entry SHA256 references:

```bash
swift run -c release --package-path . <<'SH' || true
# In practice: write a tiny throwaway Swift script that opens
# Tests/SheetMusicTests/Resources/midi01.mscz via ZIPFoundation,
# iterates entries, prints `path\t<sha256-of-extracted-bytes>` per
# entry. The values become the literals in Step 2.
SH
```
Easier: use macOS `unzip -p` plus `shasum -a 256` per entry:
```bash
cd Tests/SheetMusicTests/Resources
unzip -l midi01.mscz                                 # list entry paths
for p in $(unzip -Z1 midi01.mscz); do
    printf '%s\t' "$p"
    unzip -p midi01.mscz "$p" | shasum -a 256
done
```
Record the output. Each line is `<path>\t<sha256>  -`.

- [ ] **Step 2: Write the test using the captured snapshot**

```swift
// Tests/SheetMusicTests/Zip/ZipReaderInteropTests.swift
@testable import SheetMusicZip
import Testing
import Foundation
import CryptoKit

@Suite("ZipReader interop")
struct ZipReaderInteropTests {
    /// Replace this snapshot with the actual values captured in Step 1
    /// of Task 9. Each entry: forward-slash ZIP path → SHA256 hex of
    /// extracted bytes. The list is exhaustive — any entry the reader
    /// surfaces that's not in the snapshot fails the test.
    private static let midi01Snapshot: [String: String] = [
        // "META-INF/container.xml": "<hex sha256>",
        // "score.mscx": "<hex sha256>",
        // … fill in
    ]

    @Test
    func midi01EntriesMatchSnapshot() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz"),
            "midi01.mscz fixture not found in test bundle",
        )
        let data = try Data(contentsOf: url)
        let reader = try ZipReader(data: data)
        // Skip directory entries.
        let filePaths = reader.entries.values
            .filter { !$0.path.hasSuffix("/") }
            .map { $0.path }
            .sorted()
        #expect(Set(filePaths) == Set(Self.midi01Snapshot.keys))
        for path in filePaths {
            let bytes = try reader.read(path: path)
            let hex = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
            #expect(
                hex == Self.midi01Snapshot[path],
                "SHA256 mismatch for \(path): got \(hex)",
            )
        }
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter ZipReaderInteropTests`
Expected: PASS. If it fails because the fixture exposes ZIP features SheetMusicZip rejects (`ZIP64`, `encryption`), this is the point to halt and revisit the spec's "Supported ZIP features" matrix.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/Zip/ZipReaderInteropTests.swift
git commit -m "test(zip): snapshot midi01.mscz entries against ZipReader"
```

---

## Task 10: `ZipWriter.add` — local file header + payload

**Files:**
- Create: `Sources/SheetMusicZip/Container/ZipWriter.swift`
- Test: `Tests/SheetMusicTests/Zip/ZipWriterTests.swift`

- [ ] **Step 1: Write the failing test (round-trip a single entry)**

```swift
// Tests/SheetMusicTests/Zip/ZipWriterTests.swift
@testable import SheetMusicZip
import Testing
import Foundation

@Suite("ZipWriter")
struct ZipWriterTests {
    @Test
    func singleEntryRoundTrips() throws {
        let payload = Data("the quick brown fox".utf8)
        var writer = ZipWriter()
        try writer.add(path: "foo.txt", data: payload, method: .deflate)
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        #expect(reader.entries.count == 1)
        let bytes = try reader.read(path: "foo.txt")
        #expect(bytes == payload)
    }

    @Test
    func storedRoundTrips() throws {
        let payload = Data("plain bytes".utf8)
        var writer = ZipWriter()
        try writer.add(path: "raw.bin", data: payload, method: .stored)
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        let bytes = try reader.read(path: "raw.bin")
        #expect(bytes == payload)
        #expect(reader.entries["raw.bin"]?.method == .stored)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ZipWriterTests`
Expected: FAIL — `ZipWriter` not found.

- [ ] **Step 3: Implement ZipWriter (both `add` and a minimal `finish`)**

```swift
// Sources/SheetMusicZip/Container/ZipWriter.swift
import Foundation

/// Builds a ZIP archive in memory. Scope mirrors ZipReader's accepted
/// feature set: STORED or DEFLATE entries, UTF-8 names (gp bit 11 set),
/// no data descriptor, no ZIP64.
struct ZipWriter {
    private var buffer = BinaryWriter()
    private var records: [Record] = []

    /// Used internally to remember enough state to emit the central
    /// directory entry in `finish()`.
    private struct Record {
        let path: String
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: ZipCompressionMethod
        let localHeaderOffset: UInt32
    }

    init() {}

    mutating func add(
        path: String,
        data: Data,
        method: ZipCompressionMethod = .deflate,
    ) throws {
        guard !path.isEmpty else {
            throw ZipError.corrupted("empty entry path")
        }
        guard let nameBytes = path.data(using: .utf8) else {
            throw ZipError.corrupted("non-UTF8 entry path")
        }
        guard data.count <= UInt32.max else {
            throw ZipError.unsupportedFeature("entry > 4 GiB (ZIP64 needed)")
        }
        let localOffset = UInt32(buffer.offset)
        let crc = CRC32.compute(data)
        let payload: Data
        switch method {
        case .stored:
            payload = data
        case .deflate:
            payload = try Deflate.compress(data)
        }
        guard payload.count <= UInt32.max else {
            throw ZipError.unsupportedFeature("compressed entry > 4 GiB (ZIP64 needed)")
        }

        // local file header
        buffer.writeUInt32LE(0x04034B50)
        buffer.writeUInt16LE(20)                       // version needed
        buffer.writeUInt16LE(0x0800)                   // gp flags: bit 11 (UTF-8)
        buffer.writeUInt16LE(method.rawValue)
        buffer.writeUInt32LE(0)                        // mtime/mdate = 0
        buffer.writeUInt32LE(crc)
        buffer.writeUInt32LE(UInt32(payload.count))
        buffer.writeUInt32LE(UInt32(data.count))
        buffer.writeUInt16LE(UInt16(nameBytes.count))
        buffer.writeUInt16LE(0)                        // extra length
        buffer.writeBytes(nameBytes)
        buffer.writeBytes(payload)

        records.append(Record(
            path: path,
            crc32: crc,
            compressedSize: UInt32(payload.count),
            uncompressedSize: UInt32(data.count),
            method: method,
            localHeaderOffset: localOffset,
        ))
    }

    consuming func finish() -> Data {
        let centralDirOffset = UInt32(buffer.offset)
        for r in records {
            let nameBytes = Data(r.path.utf8)
            buffer.writeUInt32LE(0x02014B50)           // central signature
            buffer.writeUInt16LE(20)                   // version made by
            buffer.writeUInt16LE(20)                   // version needed
            buffer.writeUInt16LE(0x0800)               // gp flags
            buffer.writeUInt16LE(r.method.rawValue)
            buffer.writeUInt32LE(0)                    // mtime/mdate
            buffer.writeUInt32LE(r.crc32)
            buffer.writeUInt32LE(r.compressedSize)
            buffer.writeUInt32LE(r.uncompressedSize)
            buffer.writeUInt16LE(UInt16(nameBytes.count))
            buffer.writeUInt16LE(0)                    // extra length
            buffer.writeUInt16LE(0)                    // comment length
            buffer.writeUInt16LE(0)                    // disk number start
            buffer.writeUInt16LE(0)                    // internal attrs
            buffer.writeUInt32LE(0)                    // external attrs
            buffer.writeUInt32LE(r.localHeaderOffset)
            buffer.writeBytes(nameBytes)
        }
        let centralDirSize = UInt32(buffer.offset) - centralDirOffset

        // EOCD
        buffer.writeUInt32LE(0x06054B50)
        buffer.writeUInt16LE(0)                        // this disk
        buffer.writeUInt16LE(0)                        // disk with cd
        buffer.writeUInt16LE(UInt16(records.count))    // entries this disk
        buffer.writeUInt16LE(UInt16(records.count))    // entries total
        buffer.writeUInt32LE(centralDirSize)
        buffer.writeUInt32LE(centralDirOffset)
        buffer.writeUInt16LE(0)                        // comment length
        return buffer.data
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ZipWriterTests`
Expected: PASS (2 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicZip/Container/ZipWriter.swift Tests/SheetMusicTests/Zip/ZipWriterTests.swift
git commit -m "feat(zip): add ZipWriter.add + finish with round-trip tests"
```

---

## Task 11: `ZipWriter` — round-trip matrix

**Files:**
- Modify: `Tests/SheetMusicTests/Zip/ZipWriterTests.swift`

- [ ] **Step 1: Append parameterized round-trip cases**

```swift
@Test(arguments: [
    ("empty.bin", Data()),
    ("one.bin", Data([0x42])),
    ("small.bin", Data(repeating: 0xAA, count: 1024)),
    ("zeros.bin", Data(repeating: 0, count: 64 * 1024)),
    ("counter.bin", Data((0..<10_000).map { UInt8($0 & 0xFF) })),
])
func roundTripVariousSizesAndPatterns(name: String, payload: Data) throws {
    var writer = ZipWriter()
    try writer.add(path: name, data: payload, method: .deflate)
    let archive = writer.finish()
    let reader = try ZipReader(data: archive)
    #expect(try reader.read(path: name) == payload)
}

@Test
func multipleEntries() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", data: Data("alpha".utf8), method: .deflate)
    try writer.add(path: "b.txt", data: Data("beta".utf8), method: .stored)
    try writer.add(path: "nested/c.txt", data: Data("gamma".utf8), method: .deflate)
    let archive = writer.finish()
    let reader = try ZipReader(data: archive)
    #expect(reader.entries.count == 3)
    #expect(try reader.read(path: "a.txt") == Data("alpha".utf8))
    #expect(try reader.read(path: "b.txt") == Data("beta".utf8))
    #expect(try reader.read(path: "nested/c.txt") == Data("gamma".utf8))
}

@Test
func emptyArchiveFinishes() throws {
    var writer = ZipWriter()
    let archive = writer.finish()
    let reader = try ZipReader(data: archive)
    #expect(reader.entries.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter ZipWriterTests`
Expected: PASS (all cases — including the 5 parameterized + 2 new + 2 prior).

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/Zip/ZipWriterTests.swift
git commit -m "test(zip): expand ZipWriter round-trip matrix"
```

---

## Task 12: `ZipError` paths

**Files:**
- Test: `Tests/SheetMusicTests/Zip/ZipErrorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SheetMusicTests/Zip/ZipErrorTests.swift
@testable import SheetMusicZip
import Testing
import Foundation

@Suite("ZipError paths")
struct ZipErrorTests {
    @Test
    func truncatedArchiveThrowsNotAZip() {
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(throws: ZipError.notAZip) {
            _ = try ZipReader(data: bytes)
        }
    }

    @Test
    func zip64MarkerRejected() throws {
        // Build a valid archive then patch its central-directory entry's
        // uncompressedSize field to 0xFFFFFFFF (ZIP64 marker).
        var writer = ZipWriter()
        try writer.add(path: "x", data: Data("hello".utf8), method: .deflate)
        var bytes = writer.finish()
        // Find the central directory header (PK\1\2) and patch its
        // uncompressed-size field.
        let pattern: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let idx = bytes.range(of: Data(pattern))!.lowerBound
        // Layout: signature(4) + 20 + crc(4) + comp(4) + uncomp(4) ...
        let uncompOffset = idx + 4 + 20 + 4 + 4
        bytes.replaceSubrange(
            uncompOffset ..< uncompOffset + 4,
            with: Data([0xFF, 0xFF, 0xFF, 0xFF]),
        )
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: bytes)
        }
    }

    @Test
    func encryptionFlagRejected() throws {
        var writer = ZipWriter()
        try writer.add(path: "x", data: Data("hello".utf8), method: .deflate)
        var bytes = writer.finish()
        let pattern: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let idx = bytes.range(of: Data(pattern))!.lowerBound
        // Layout: signature(4) + version-made-by(2) + version-needed(2)
        //         + gp-flags(2)
        let flagsOffset = idx + 4 + 2 + 2
        bytes[flagsOffset] |= 0x01
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: bytes)
        }
    }

    @Test
    func unknownMethodRejected() throws {
        var writer = ZipWriter()
        try writer.add(path: "x", data: Data("hello".utf8), method: .stored)
        var bytes = writer.finish()
        // Patch the central-directory method to 99 (AES marker).
        let pattern: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let idx = bytes.range(of: Data(pattern))!.lowerBound
        let methodOffset = idx + 4 + 2 + 2 + 2
        bytes.replaceSubrange(
            methodOffset ..< methodOffset + 2,
            with: Data([0x63, 0x00]),               // 99 LE
        )
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: bytes)
        }
    }
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter ZipErrorTests`
Expected: PASS (4 cases).

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/Zip/ZipErrorTests.swift
git commit -m "test(zip): cover unsupported-feature and truncation paths"
```

---

## Task 13: Rewrite `MSCZReader` on `SheetMusicZip`

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCZReader.swift`

- [ ] **Step 1: Replace the file in full**

Replace `Sources/SheetMusicMSCX/MSCZReader.swift` entirely with the version below. Drops:
- the top-of-file `#if !os(Android)` ... `#endif` wrap,
- the in-function `#if os(Android)` stubs,
- the `ZIPFoundation` import.

Switches to `SheetMusicZip`'s `ZipReader`.

```swift
import Foundation
import SheetMusicCore
import SheetMusicZip

/// Reads `.mscz` (ZIP) containers and returns the `Score` contained in
/// the main `.mscx` entry. When the archive ships an
/// `audiosettings.json` (MuseScore 4), per-part preset overrides are
/// merged into the score so consumers see the sounds MuseScore actually
/// plays. Other auxiliary resources (style, thumbnails, pictures,
/// excerpts, …) are ignored.
///
/// Mirrors `mu::engraving::MscReader::mainFileName` /
/// `::readScoreFile`: prefer the exact name `score.mscx`, and fall back
/// to the first `.mscx` entry at archive root. Filename-based main-name
/// matching (using the archive's own file name) is skipped because the
/// `Data` overload has no filename context.
public enum MSCZReader {
    /// Parse `.mscz` bytes into a `Score`.
    public static func parse(_ data: Data) throws -> Score {
        let reader = try openReader(data)
        let mainPath = try resolveMainPath(in: reader)
        let mscxData: Data
        do {
            mscxData = try reader.read(path: mainPath)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to extract \(mainPath): \(error)",
            )
        }
        let score = try MSCXParser.parse(mscxData)
        let settings = audioSettings(in: reader)
        return settings.map { apply($0, to: score) } ?? score
    }

    /// Read `.mscz` bytes from a file URL and parse into a `Score`.
    /// I/O failures are wrapped in `SheetMusicError.ioError`.
    public static func parse(contentsOf url: URL) throws -> Score {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
        return try parse(data)
    }

    private static func openReader(_ data: Data) throws -> ZipReader {
        do {
            return try ZipReader(data: data)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "could not open ZIP: \(error)",
            )
        }
    }

    private static func resolveMainPath(in reader: ZipReader) throws -> String {
        if reader.contains(path: "score.mscx") {
            return "score.mscx"
        }
        // Sorted for determinism.
        let candidates = reader.entries.keys
            .filter { !$0.contains("/") && $0.lowercased().hasSuffix(".mscx") }
            .sorted()
        guard let first = candidates.first else {
            throw SheetMusicError.corruptedContainer(
                reason: "no main .mscx entry found in archive",
            )
        }
        return first
    }

    private static func audioSettings(in reader: ZipReader) -> AudioSettings? {
        guard reader.contains(path: "audiosettings.json"),
              let data = try? reader.read(path: "audiosettings.json"),
              let settings = try? AudioSettings.parse(data)
        else { return nil }
        return settings
    }

    /// (`apply` body unchanged from the previous file — copy verbatim,
    /// including its existing doc comment about drumset-skip behaviour.)
    private static func apply(
        _ settings: AudioSettings, to score: Score,
    ) -> Score {
        guard !settings.presets.isEmpty else { return score }
        var result = score
        for partIdx in result.parts.indices {
            guard
                let preset = settings.presets[result.parts[partIdx].id],
                !result.parts[partIdx].instrument.channels.isEmpty,
                !result.parts[partIdx].instrument.useDrumset
            else { continue }
            if let program = preset.program {
                result.parts[partIdx].instrument.channels[0].program = program
            }
            if let bank = preset.bank {
                result.parts[partIdx].instrument.channels[0].bank = bank
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Verify build (macOS)**

Run: `swift build`
Expected: success. (Tests will fail until Package.swift is updated in Task 16.)

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZReader.swift
git commit -m "refactor(mscz): port MSCZReader to SheetMusicZip"
```

---

## Task 14: Rewrite `MSCZWriter` on `SheetMusicZip`

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCZWriter.swift`

- [ ] **Step 1: Replace the file in full**

```swift
import Foundation
import SheetMusicCore
import SheetMusicZip

/// Packages already-serialized `.mscx` XML bytes into a minimal `.mscz`
/// (ZIP) container.
///
/// This is the low-level writer — it does NOT serialize a `Score`.
/// The high-level overloads delegate to `MSCXEncoder` to produce the
/// XML bytes, then wrap them. The produced archive contains only the
/// provided XML bytes at the given `mainFileName`; no
/// `META-INF/container.xml`, no auxiliary resources. MuseScore's own
/// `MscReader::readScoreFile` resolves the main score by entry name,
/// so the minimal archive round-trips through both this library and
/// MuseScore Studio.
public enum MSCZWriter {
    public static func write(
        mscxData: Data,
        mainFileName: String = "score.mscx",
    ) throws -> Data {
        try validate(mainFileName: mainFileName)
        var writer = ZipWriter()
        do {
            try writer.add(path: mainFileName, data: mscxData, method: .deflate)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to add entry \(mainFileName): \(error)",
            )
        }
        return writer.finish()
    }

    public static func write(
        mscxData: Data,
        to url: URL,
        mainFileName: String = "score.mscx",
    ) throws {
        let bytes = try write(mscxData: mscxData, mainFileName: mainFileName)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    public static func write(
        score: Score, mainFileName: String = "score.mscx",
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    public static func write(
        score: Score, to url: URL, mainFileName: String = "score.mscx",
    ) throws {
        let bytes = try write(score: score, mainFileName: mainFileName)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    public static func write(
        score: Score, options: MSCXEncoderOptions,
        mainFileName: String = "score.mscx",
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score, options: options)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    public static func write(
        score: Score, options: MSCXEncoderOptions, to url: URL,
        mainFileName: String = "score.mscx",
    ) throws {
        let bytes = try write(
            score: score, options: options, mainFileName: mainFileName,
        )
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    private static func validate(mainFileName: String) throws {
        guard !mainFileName.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                reason: "mainFileName must not be empty",
            )
        }
        guard !mainFileName.contains("/") else {
            throw SheetMusicError.corruptedContainer(
                reason: "mainFileName must not contain '/': \(mainFileName)",
            )
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZWriter.swift
git commit -m "refactor(mscz): port MSCZWriter to SheetMusicZip"
```

---

## Task 15: Rewrite `MXLReader` + `MXLTestBuilder`

**Files:**
- Modify: `Sources/SheetMusicMusicXML/MXL/MXLReader.swift`
- Modify: `Tests/SheetMusicTests/Helpers/MXLTestBuilder.swift`

- [ ] **Step 1: Replace `MXLReader` in full**

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools
import SheetMusicZip

/// Reads `.mxl` (compressed MusicXML) archives: resolves the rootfile
/// from `META-INF/container.xml`, extracts that entry, and hands the
/// bytes off to `MusicXMLParser.parse(_:)`.
enum MXLReader {
    private static let containerPath = "META-INF/container.xml"
    private static let musicXMLMediaType = "application/vnd.recordare.musicxml+xml"

    static func extractRootScore(mxlData: Data) throws -> Data {
        let reader = try openReader(mxlData)
        let roots = try readRootFiles(in: reader)
        let chosen = pickPreferred(roots)
        do {
            return try reader.read(path: chosen.path)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: failed to extract \(chosen.path): \(error)",
            )
        }
    }

    static func rootFiles(mxlData: Data) throws -> [MusicXMLContainer.RootFile] {
        let reader = try openReader(mxlData)
        return try readRootFiles(in: reader)
    }

    private static func openReader(_ data: Data) throws -> ZipReader {
        do {
            return try ZipReader(data: data)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: could not open ZIP: \(error)",
            )
        }
    }

    private static func readRootFiles(in reader: ZipReader) throws -> [MusicXMLContainer.RootFile] {
        guard reader.contains(path: containerPath) else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml missing or has no rootfiles",
            )
        }
        let data: Data
        do {
            data = try reader.read(path: containerPath)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: failed to extract container.xml: \(error)",
            )
        }
        let root: XMLTreeNode
        do {
            root = try XMLTreeParser.parse(data)
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml is not valid XML: \(error)",
            )
        }
        guard root.name == "container" else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml root is <\(root.name)>, expected <container>",
            )
        }
        let rootsNode = root.first("rootfiles")
        let entries = rootsNode?.all("rootfile") ?? []
        let result: [MusicXMLContainer.RootFile] = entries.compactMap { node in
            guard let path = node.attributes["full-path"], !path.isEmpty else {
                return nil
            }
            return MusicXMLContainer.RootFile(
                path: path,
                mediaType: node.attributes["media-type"],
            )
        }
        guard !result.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml has no <rootfile> entries",
            )
        }
        // Verify each rootfile actually exists in the archive — preserves
        // the "rootfile not found" error path of the previous version.
        for r in result where !reader.contains(path: r.path) {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: rootfile '\(r.path)' not found in archive",
            )
        }
        return result
    }

    private static func pickPreferred(_ roots: [MusicXMLContainer.RootFile]) -> MusicXMLContainer.RootFile {
        if let match = roots.first(where: { $0.mediaType == musicXMLMediaType }) {
            return match
        }
        return roots[0]
    }
}
```

- [ ] **Step 2: Replace `MXLTestBuilder` in full**

```swift
// Tests/SheetMusicTests/Helpers/MXLTestBuilder.swift
import Foundation
import SheetMusicZip

/// Builds `.mxl` archive bytes at test time so we don't need to ship a
/// physical `.mxl` fixture. Writes a minimal `META-INF/container.xml`
/// plus one MusicXML entry.
enum MXLTestBuilder {
    static func wrap(xml: Data, entryName: String = "score.xml") throws -> Data {
        let container = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container>
          <rootfiles>
            <rootfile full-path="\(entryName)" media-type="application/vnd.recordare.musicxml+xml"/>
          </rootfiles>
        </container>
        """.utf8)
        return try buildArchive(entries: [
            ("META-INF/container.xml", container),
            (entryName, xml),
        ])
    }

    static func wrapWithoutContainer(xml: Data, entryName: String = "score.xml") throws -> Data {
        try buildArchive(entries: [(entryName, xml)])
    }

    static func wrapWithDanglingRootfile(xml: Data) throws -> Data {
        let container = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container>
          <rootfiles>
            <rootfile full-path="missing.xml" media-type="application/vnd.recordare.musicxml+xml"/>
          </rootfiles>
        </container>
        """.utf8)
        return try buildArchive(entries: [
            ("META-INF/container.xml", container),
            ("score.xml", xml),
        ])
    }

    private static func buildArchive(entries: [(path: String, data: Data)]) throws -> Data {
        var writer = ZipWriter()
        for entry in entries {
            try writer.add(path: entry.path, data: entry.data, method: .deflate)
        }
        return writer.finish()
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicMusicXML/MXL/MXLReader.swift Tests/SheetMusicTests/Helpers/MXLTestBuilder.swift
git commit -m "refactor(mxl): port MXLReader and MXLTestBuilder to SheetMusicZip"
```

---

## Task 16: Update `Package.swift` — drop ZIPFoundation

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Drop ZIPFoundation, wire SheetMusicZip into consumers**

Edit `Package.swift`:

1. **Remove the package dependency entirely.** Delete `.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")` from `packageDependencies`. The `if !isAndroid { packageDependencies += [...] }` block becomes vacuous — either remove the whole block or leave it empty. (Preference: remove.)

2. **Collapse `SheetMusicMSCX` deps to a single branch (no more `isAndroid`).** Replace the entire ternary `dependencies: isAndroid ? [...] : [...]` form with:
```swift
.target(
    name: "SheetMusicMSCX",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicXMLTools",
        "SheetMusicZip",
    ],
),
```

3. **Same for `SheetMusicMusicXML`:**
```swift
.target(
    name: "SheetMusicMusicXML",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicXMLTools",
        "SheetMusicZip",
    ],
),
```

4. **Update `SheetMusicTests` deps.** In *both* the `isAndroid` and non-Android branches, replace `.product(name: "ZIPFoundation", package: "ZIPFoundation")` with `"SheetMusicZip"`. (The Android branch may already have had `SheetMusicZip` added in Task 2 step 1; if so, remove the ZIPFoundation entry from the non-Android branch and confirm the Android branch is unchanged.)

5. **Verify the `SheetMusicZip` target literal** carries:
```swift
.target(
    name: "SheetMusicZip",
    linkerSettings: [
        .linkedLibrary("z", .when(platforms: [.linux, .android])),
    ],
),
```

- [ ] **Step 2: Confirm grep-clean**

Run: `grep -n ZIPFoundation Package.swift`
Expected: no output.

- [ ] **Step 3: Verify both manifest shapes resolve**

Run:
```bash
swift package describe > /dev/null
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe > /dev/null
```
Expected: both exit 0.

- [ ] **Step 4: Verify full `swift test` (macOS)**

Run: `swift test`
Expected: 100% green — all previously-green tests stay green, the new Zip/ tests all pass. If `MSCZReaderTests` / `MSCZWriterTests` fail because they are still `#if !os(Android)`-gated and the test target deps changed, that's fine — Task 17 removes the gates.

- [ ] **Step 5: Commit**

```bash
git add Package.swift
git commit -m "build: drop ZIPFoundation dep, wire SheetMusicZip into MSCX/MusicXML/Tests"
```

---

## Task 17: Lift Android restrictions from tests + docs

**Files:**
- Modify: `Tests/SheetMusicTests/MSCZReaderTests.swift`
- Modify: `Tests/SheetMusicTests/MSCZWriterTests.swift`
- Modify: `Tests/SheetMusicTests/MSCXRoundTripTests.swift` (if its Android gate was *only* about ZIP)
- Modify: `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift` (ditto)
- Modify: `Tests/SheetMusicTests/MusicXMLImportTests.swift` (ditto)
- Modify: `CLAUDE.md`

For each test file: open it, locate the leading `#if !os(Android)` ... trailing `#endif`, and check whether the file imports any Apple framework (`SwiftUI`, `AVFoundation`, `CoreText`, `AppKit`, `UIKit`, `PDFKit`, `CoreGraphics`) or `@testable import`s an Apple-only sub-library (`SheetMusicLayout` / `SheetMusicUI` / `SheetMusicAudio` / `SheetMusicPDF`). If yes, **keep the gate**. If the gate exists solely because the file used `MSCZReader` / `MSCZWriter` / `MXLReader` / `MXLTestBuilder` and nothing else Apple-only, **remove the gate**.

- [ ] **Step 1: Remove gates from MSCZ test files (always safe — ZIP-only)**

Edit `Tests/SheetMusicTests/MSCZReaderTests.swift` and `Tests/SheetMusicTests/MSCZWriterTests.swift`:
- Delete the leading `#if !os(Android)` line.
- Delete the trailing `#endif` line.

- [ ] **Step 2: Audit the remaining gated files**

For each of `MSCXRoundTripTests.swift` / `MSCXEncoderMS3Tests.swift` / `MusicXMLImportTests.swift`:

```bash
head -20 Tests/SheetMusicTests/<file>.swift
grep -E '^(import|@testable import) ' Tests/SheetMusicTests/<file>.swift
```

If only Foundation / Testing / SheetMusic{Core,MSCX,MusicXML,XMLTools,MIDI,Zip} appear → safe to remove the gate (delete leading `#if !os(Android)` and trailing `#endif`). Otherwise leave it.

- [ ] **Step 3: Re-run `gate-android-tests.sh` to confirm it stays idempotent**

Run: `Scripts/gate-android-tests.sh`
Expected: existing gates re-applied; no spurious new gates on the files just un-gated (they shouldn't import Apple frameworks).

- [ ] **Step 4: Update `CLAUDE.md`**

In the worktree's `CLAUDE.md`, locate the "Format support matrix on Android (Phase 1)" section (a paragraph that begins with "ZIPFoundation 0.9.20's manifest declares its `CZLib`…"). Replace it with:

```markdown
### Format support on Android

`.mscz` and `.mxl` are fully supported on Android via the in-house
`SheetMusicZip` target (raw DEFLATE through system `libz`). No
additional setup is required beyond the Phase 1 toolchain.
```

- [ ] **Step 5: Verify macOS `swift test`**

Run: `swift test`
Expected: 100% green.

- [ ] **Step 6: Commit**

```bash
git add Tests/SheetMusicTests/MSCZReaderTests.swift \
        Tests/SheetMusicTests/MSCZWriterTests.swift \
        Tests/SheetMusicTests/MSCXRoundTripTests.swift \
        Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift \
        Tests/SheetMusicTests/MusicXMLImportTests.swift \
        CLAUDE.md
git commit -m "android: lift Phase 1 ZIP gating now that SheetMusicZip is in"
```

---

## Task 18: Cross-platform verification + manual smoke

**Files:** — (none modified; verification only)

- [ ] **Step 1: macOS full-suite test**

Run: `swift test`
Expected: 100% green, including all `Zip/` tests, all `MSCZ*Tests`, all `MXL*Tests`, all twelve `MidiExportTests` `.mscz`-input cases.

- [ ] **Step 2: SwiftLint clean**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 3: File-length cap on new sources**

Run:
```bash
find Sources/SheetMusicZip -name '*.swift' -exec wc -l {} +
```
Expected: every file ≤ 300 lines. If any exceeds, split it (e.g.
`ZipReader.swift` → `ZipReader.swift` + `ZipReader+ParseEntry.swift`)
before the final commit. Update the file map at the top of this plan
if you split anything.

- [ ] **Step 4: Android cross-compile + emulator test**

Boot an emulator on API ≥ 28, then:
```bash
TOOLCHAINS=org.swift.632202605101a Scripts/android-test.sh aarch64
```
Expected: full `swift test` suite green on the emulator. Test count
should now exceed the Phase 1 baseline (679 tests / 116 suites) because
`MSCZReaderTests` / `MSCZWriterTests` / the new `Zip/` tests now run
under `!os(Android)` ungated.

If the Android run hits `import zlib` symbol issues, drop to the
fallback path in the spec's risk table (vendored `Sources/CZlibShim/`
target). That is out-of-plan-band and warrants a brief
unblock-or-pivot conversation with the user before adding new sources.

- [ ] **Step 5: Manual smoke — SheetMusicExampleMac**

In Example, regenerate Xcode project if needed:
```bash
cd Example && xcodegen generate
```
Open Xcode, build & run `SheetMusicExampleMac`. Verify (manual):
1. **Open** a `.mscz` from `Tests/SheetMusicTests/Resources/midi01.mscz` (or any user-supplied `.mscz`) → score loads correctly.
2. **Save** the open score back out as a new `.mscz` to a scratch location → no error.
3. **MIDI export** of the open score → SMF written, plays correctly in any DAW or media player.

- [ ] **Step 6: Verify a SheetMusicZip-written `.mscz` opens in MuseScore Studio 4**

Take the `.mscz` written in step 5.2 and open it in MuseScore Studio 4
(or 3.6.2 if convenient). Score must open without "corrupted file"
errors and display the same notes as the input.

- [ ] **Step 7: Final acceptance grep**

Run: `grep -rn ZIPFoundation Sources Tests Package.swift`
Expected: no output anywhere in `Sources/`, `Tests/`, or `Package.swift`.

- [ ] **Step 8: Update project memory**

Edit `~/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_android_port_roadmap.md` to:
- mark Phase 1.6 as completed (give the commit shape and date),
- strike Phase 1.6 from the "remaining" list (leaving only Phases 2 / 3 / 4).

- [ ] **Step 9: PR-ready commit set**

Verify the commit log is a clean sequence of the tasks above (one commit per task in this plan, plus any pre-existing commits on the branch). No fix-up commits — squash any intermediate "wip" / "oops" commits via interactive rebase before pushing.

```bash
git log --oneline feature/android-toolchain ^main | head -40
```

The branch is now ready for PR to `main`. PR title suggestion:
`feat(android): SheetMusicZip — drop ZIPFoundation, restore full ZIP support on Android`.
