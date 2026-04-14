# MSCZ Reading + Writing + URL-Based API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `.mscz` (ZIP) reading and a minimal `.mscz` writer to `SheetMusicMSCX`, add file-URL overloads across the public API, and expose everything from the `SheetMusic` umbrella.

**Architecture:** `MSCZReader` unzips, locates the main `.mscx` entry (mirroring MuseScore's `MscReader::mainFileName` / `readScoreFile`), and delegates to the existing `MSCXParser`. `MSCZWriter` packages caller-supplied `.mscx` XML bytes into a minimal single-entry ZIP. Both add `Data` and `URL` forms. Score→XML encoding is explicitly out of scope.

**Tech Stack:** Swift 6.3, Swift Package Manager, ZIPFoundation 0.9.20 (already a dependency), Swift Testing (`import Testing`).

---

## Reference

- Spec: `docs/superpowers/specs/2026-04-14-mscz-reading-writing-design.md`
- MuseScore algorithm reference: `MuseScore/src/engraving/infrastructure/mscreader.{h,cpp}` (GPL-3.0, submodule only — read, do not copy)
- Existing parser: `Sources/SheetMusicMSCX/MSCXParser.swift`
- Error type: `Sources/SheetMusicCore/SheetMusicError.swift`
- Umbrella façade: `Sources/SheetMusic/SheetMusic.swift`

## ZIPFoundation cheatsheet (used by this plan)

```swift
import ZIPFoundation

// Read in-memory archive
let archive = try Archive(data: msczBytes, accessMode: .read)
guard let entry = archive["score.mscx"] else { /* not found */ }
var out = Data()
_ = try archive.extract(entry) { chunk in out.append(chunk) }

// Iterate entries (Archive conforms to Sequence of Entry)
for entry in archive where entry.type == .file { /* entry.path */ }

// Create in-memory archive
let archive = try Archive(accessMode: .create) // Data() default
try archive.addEntry(
    with: "score.mscx",
    type: .file,
    uncompressedSize: Int64(mscxData.count),
    compressionMethod: .deflate
) { position, size in
    let start = Int(position)
    let end = min(start + size, mscxData.count)
    return mscxData.subdata(in: start..<end)
}
let bytes: Data = archive.data!   // in-memory archives only
```

All ZIPFoundation errors bubble up as `ZIPFoundation.Archive.ArchiveError` (an `Error`). We wrap them in `SheetMusicError.corruptedContainer(reason:)` at every call site.

---

## Task 1: Add two error cases to `SheetMusicError`

**Files:**
- Modify: `Sources/SheetMusicCore/SheetMusicError.swift`
- Test: `Tests/SheetMusicTests/SheetMusicErrorTests.swift` (existing)

- [ ] **Step 1: Read the existing error file to confirm shape**

Run:
```bash
cat Sources/SheetMusicCore/SheetMusicError.swift
```

Expected content is the enum with three cases shown in the spec.

- [ ] **Step 2: Write a failing test for `corruptedContainer` existence**

Read `Tests/SheetMusicTests/SheetMusicErrorTests.swift` first. Append inside the existing `@Suite`:

```swift
    @Test func corruptedContainerCarriesReason() {
        let error = SheetMusicError.corruptedContainer(reason: "bad zip")
        guard case .corruptedContainer(let reason) = error else {
            Issue.record("expected corruptedContainer")
            return
        }
        #expect(reason == "bad zip")
    }

    @Test func ioErrorPreservesURLAndUnderlying() {
        let url = URL(fileURLWithPath: "/tmp/missing.mscz")
        let underlying = NSError(domain: "TestDomain", code: 42)
        let error = SheetMusicError.ioError(url: url, underlying: underlying)
        guard case .ioError(let u, let e) = error else {
            Issue.record("expected ioError")
            return
        }
        #expect(u == url)
        #expect((e as NSError).code == 42)
    }
```

- [ ] **Step 3: Run the new tests to see them fail**

Run:
```bash
swift test --filter SheetMusicErrorTests.corruptedContainerCarriesReason
```
Expected: compile error — `corruptedContainer` not a member.

- [ ] **Step 4: Add the two cases**

Edit `Sources/SheetMusicCore/SheetMusicError.swift` to read:

```swift
import Foundation

/// Errors raised by SheetMusic libraries when reading mscx data, building
/// the score model, or rendering MIDI.
public enum SheetMusicError: Error, Sendable {
    /// XML was syntactically invalid (could not be parsed by Foundation `XMLParser`).
    case invalidXML(underlying: Error)
    /// XML parsed but a required element/attribute was missing or malformed.
    case malformedScore(reason: String)
    /// A score element exists in the file but is not yet supported by the library.
    case unsupportedFeature(name: String, location: String?)
    /// An `.mscz` / ZIP container is unreadable: bytes are not a valid ZIP,
    /// the archive has no main `.mscx` entry, an entry failed to
    /// decompress, or archive creation failed on the writer side.
    case corruptedContainer(reason: String)
    /// Wrapping for `Data(contentsOf:)` / `Data.write(to:)` failures in
    /// the URL-based API overloads. The original error is preserved.
    case ioError(url: URL, underlying: Error)
}
```

- [ ] **Step 5: Run the new tests, they pass; run the full suite, still green**

Run:
```bash
swift test --filter SheetMusicErrorTests
swift test
```
Expected: all green (existing 48 + 2 new = 50).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/SheetMusicError.swift \
        Tests/SheetMusicTests/SheetMusicErrorTests.swift
git commit -m "core: add corruptedContainer and ioError SheetMusicError cases"
```

---

## Task 2: `MSCXParser.parse(contentsOf:)` URL overload

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCXParser.swift`
- Create: `Tests/SheetMusicTests/MSCXParserURLTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/MSCXParserURLTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct MSCXParserURLTests {
    @Test func parseContentsOfURLMatchesDataOverload() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let viaData = try MSCXParser.parse(Data(contentsOf: url))
        let viaURL = try MSCXParser.parse(contentsOf: url)
        #expect(viaData == viaURL)
    }

    @Test func parseContentsOfMissingURLThrowsIOError() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-there.mscx")
        do {
            _ = try MSCXParser.parse(contentsOf: missing)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .ioError(let u, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(u == missing)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
swift test --filter MSCXParserURLTests
```
Expected: compile error — no member `parse(contentsOf:)` on `MSCXParser`.

- [ ] **Step 3: Add the URL overload**

Replace `Sources/SheetMusicMSCX/MSCXParser.swift` with:

```swift
import Foundation
import SheetMusicCore

/// Public façade that turns mscx XML bytes into a `Score`.
public enum MSCXParser {
    /// Parse uncompressed `.mscx` XML bytes into an in-memory `Score`.
    /// Throws `SheetMusicError.invalidXML` for ill-formed XML and
    /// `SheetMusicError.malformedScore` for missing required elements.
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        return try Score.decode(root)
    }

    /// Read `.mscx` XML from a file URL and parse into a `Score`.
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
}
```

- [ ] **Step 4: Run the tests; confirm pass**

Run:
```bash
swift test --filter MSCXParserURLTests
swift test
```
Expected: all green (52 tests now).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXParser.swift \
        Tests/SheetMusicTests/MSCXParserURLTests.swift
git commit -m "mscx: add MSCXParser.parse(contentsOf:) URL overload"
```

---

## Task 3: Add `midi01.mscz` test fixture

**Files:**
- Create: `Tests/SheetMusicTests/Resources/midi01.mscz`
- Modify: `Tests/SheetMusicTests/Resources/LICENSE`

- [ ] **Step 1: Generate the fixture**

Run (from repo root):
```bash
set -e
TMP=$(mktemp -d)
cp Tests/SheetMusicTests/Resources/midi01.mscx "$TMP/score.mscx"
( cd "$TMP" && zip -qX9 midi01.mscz score.mscx )
cp "$TMP/midi01.mscz" Tests/SheetMusicTests/Resources/midi01.mscz
rm -rf "$TMP"
/usr/bin/unzip -l Tests/SheetMusicTests/Resources/midi01.mscz
```

Expected `unzip -l` output: exactly one entry, `score.mscx`, at the archive root, uncompressed size matching `midi01.mscx` byte size.

- [ ] **Step 2: Append provenance note to Resources/LICENSE**

Read the current file first, then append:

```
The midi01.mscz fixture is simply a ZIP-archived copy of midi01.mscx —
same GPL-3.0 provenance, no additional content. Produced with:

    zip -qX9 midi01.mscz score.mscx

where score.mscx is a byte-identical copy of midi01.mscx renamed to
the default MuseScore main-file name.
```

- [ ] **Step 3: Verify Bundle discovery in a throwaway probe**

The Package manifest uses `.process("Resources")`, which copies every
file under `Resources/` regardless of extension, so no manifest change
is required. Sanity-check:

```bash
swift build 2>&1 | tail -5
```

Expected: no warnings about `midi01.mscz` being ignored.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/Resources/midi01.mscz \
        Tests/SheetMusicTests/Resources/LICENSE
git commit -m "tests: add midi01.mscz fixture (ZIP of midi01.mscx)"
```

---

## Task 4: `MSCZReader.parse(_: Data)` — main path and resolution fallback

**Files:**
- Create: `Sources/SheetMusicMSCX/MSCZReader.swift`
- Create: `Tests/SheetMusicTests/MSCZReaderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/MSCZReaderTests.swift`:

```swift
import Foundation
import ZIPFoundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct MSCZReaderTests {
    @Test func parseMatchesDirectMSCX() throws {
        let mscz = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let msczScore = try MSCZReader.parse(Data(contentsOf: mscz))
        let mscxScore = try MSCXParser.parse(Data(contentsOf: mscx))
        #expect(msczScore == mscxScore)
    }

    @Test func corruptZipThrowsCorruptedContainer() {
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        do {
            _ = try MSCZReader.parse(junk)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .corruptedContainer = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func emptyZipThrowsCorruptedContainer() throws {
        // Build an archive that has no entries at all.
        let archive = try Archive(accessMode: .create)
        let empty = try #require(archive.data)
        do {
            _ = try MSCZReader.parse(empty)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .corruptedContainer(let reason) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(reason.lowercased().contains("mscx"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func fallbackFileNameRenamedMainEntry() throws {
        // Zip only contains "renamed.mscx" at root — the rule-2 fallback
        // in MSCZReader should still locate it.
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxBytes = try Data(contentsOf: mscx)
        let archive = try Archive(accessMode: .create)
        try archive.addEntry(
            with: "renamed.mscx",
            type: .file,
            uncompressedSize: Int64(mscxBytes.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, mscxBytes.count)
            return mscxBytes.subdata(in: start..<end)
        }
        let msczBytes = try #require(archive.data)
        let score = try MSCZReader.parse(msczBytes)
        #expect(score.division == 480)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
swift test --filter MSCZReaderTests
```
Expected: compile error — `MSCZReader` undefined.

- [ ] **Step 3: Implement `MSCZReader`**

Create `Sources/SheetMusicMSCX/MSCZReader.swift`:

```swift
import Foundation
import SheetMusicCore
import ZIPFoundation

/// Reads `.mscz` (ZIP) containers and returns the `Score` contained
/// in the main `.mscx` entry. Auxiliary resources inside the archive
/// (style, thumbnails, pictures, excerpts, audio, …) are ignored in
/// this release.
///
/// Mirrors `mu::engraving::MscReader::mainFileName` /
/// `::readScoreFile`: prefer the exact name `score.mscx`, and fall
/// back to the first `.mscx` entry at archive root. Filename-based
/// main-name matching (using the archive's own file name) is skipped
/// because the `Data` overload has no filename context.
public enum MSCZReader {
    /// Parse `.mscz` bytes into a `Score`.
    public static func parse(_ data: Data) throws -> Score {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "could not open ZIP: \(error)"
            )
        }
        let entry = try resolveMainEntry(in: archive)
        let mscxData = try extract(entry, from: archive)
        return try MSCXParser.parse(mscxData)
    }

    /// Read `.mscz` bytes from a file URL and parse into a `Score`.
    /// I/O failures are wrapped in `SheetMusicError.ioError`.
    public static func parse(contentsOf url: URL) throws -> Score {
        // Added in Task 5.
        fatalError("filled in Task 5")
    }

    private static func resolveMainEntry(in archive: Archive) throws -> Entry {
        if let exact = archive["score.mscx"], exact.type == .file {
            return exact
        }
        for entry in archive where entry.type == .file {
            let path = entry.path
            guard !path.contains("/") else { continue }
            if path.lowercased().hasSuffix(".mscx") {
                return entry
            }
        }
        throw SheetMusicError.corruptedContainer(
            reason: "no main .mscx entry found in archive"
        )
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var buffer = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                buffer.append(chunk)
            }
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to extract \(entry.path): \(error)"
            )
        }
        return buffer
    }
}
```

Note: `parse(contentsOf:)` is a stub (`fatalError`) — we add it in
Task 5 after its tests exist. The tests in this task do not call that
path, so the stub is safe.

- [ ] **Step 4: Run the tests; confirm pass**

Run:
```bash
swift test --filter MSCZReaderTests
```
Expected: all four tests pass.

- [ ] **Step 5: Run the full suite**

Run:
```bash
swift test
```
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZReader.swift \
        Tests/SheetMusicTests/MSCZReaderTests.swift
git commit -m "mscx: add MSCZReader.parse(_: Data) with main-entry fallback"
```

---

## Task 5: `MSCZReader.parse(contentsOf:)` URL overload

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCZReader.swift`
- Modify: `Tests/SheetMusicTests/MSCZReaderTests.swift`

- [ ] **Step 1: Add failing tests for the URL overload**

Append inside the existing `@Suite struct MSCZReaderTests`:

```swift
    @Test func parseContentsOfURLMatchesDataOverload() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let viaData = try MSCZReader.parse(Data(contentsOf: url))
        let viaURL = try MSCZReader.parse(contentsOf: url)
        #expect(viaData == viaURL)
    }

    @Test func parseContentsOfMissingURLThrowsIOError() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-there.mscz")
        do {
            _ = try MSCZReader.parse(contentsOf: missing)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .ioError(let u, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(u == missing)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
swift test --filter MSCZReaderTests.parseContentsOfURLMatchesDataOverload
```
Expected: FAIL via `fatalError` stub — test runner reports a crash.

- [ ] **Step 3: Replace the stub with a real implementation**

In `Sources/SheetMusicMSCX/MSCZReader.swift`, replace the `parse(contentsOf:)` stub with:

```swift
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
```

- [ ] **Step 4: Run tests; confirm pass**

Run:
```bash
swift test --filter MSCZReaderTests
swift test
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZReader.swift \
        Tests/SheetMusicTests/MSCZReaderTests.swift
git commit -m "mscx: add MSCZReader.parse(contentsOf:) URL overload"
```

---

## Task 6: `MSCZWriter.write(mscxData:)` — in-memory packaging

**Files:**
- Create: `Sources/SheetMusicMSCX/MSCZWriter.swift`
- Create: `Tests/SheetMusicTests/MSCZWriterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/SheetMusicTests/MSCZWriterTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct MSCZWriterTests {
    @Test func roundTripDefaultMainName() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let msczData = try MSCZWriter.write(mscxData: mscxData)
        let score = try MSCZReader.parse(msczData)
        let direct = try MSCXParser.parse(mscxData)
        #expect(score == direct)
    }

    @Test func roundTripCustomMainName() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let msczData = try MSCZWriter.write(
            mscxData: mscxData,
            mainFileName: "renamed.mscx"
        )
        // Must round-trip via the reader's rule-2 fallback.
        let score = try MSCZReader.parse(msczData)
        #expect(score.division == 480)
    }

    @Test func emptyMainNameThrows() {
        let bytes = Data([0x3C, 0x78, 0x6D, 0x6C]) // "<xml"
        do {
            _ = try MSCZWriter.write(mscxData: bytes, mainFileName: "")
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .corruptedContainer = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func nestedMainNameThrows() {
        let bytes = Data([0x3C, 0x78, 0x6D, 0x6C])
        do {
            _ = try MSCZWriter.write(mscxData: bytes, mainFileName: "sub/a.mscx")
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .corruptedContainer = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
swift test --filter MSCZWriterTests
```
Expected: compile error — `MSCZWriter` undefined.

- [ ] **Step 3: Implement the Data overload**

Create `Sources/SheetMusicMSCX/MSCZWriter.swift`:

```swift
import Foundation
import SheetMusicCore
import ZIPFoundation

/// Packages already-serialized `.mscx` XML bytes into a minimal
/// `.mscz` (ZIP) container.
///
/// This is the low-level writer — it does NOT serialize a `Score`.
/// A high-level `write(score:)` overload is out of scope until a
/// `Score → mscx XML` encoder exists. The produced archive contains
/// only the provided XML bytes at the given `mainFileName`; no
/// `META-INF/container.xml`, no auxiliary resources. MuseScore's own
/// `MscReader::readScoreFile` resolves the main score by entry name,
/// so the minimal archive round-trips through both this library and
/// MuseScore Studio.
public enum MSCZWriter {
    /// Package `.mscx` XML bytes into `.mscz` bytes.
    public static func write(
        mscxData: Data,
        mainFileName: String = "score.mscx"
    ) throws -> Data {
        try validate(mainFileName: mainFileName)
        let archive: Archive
        do {
            archive = try Archive(accessMode: .create)
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "could not create archive: \(error)"
            )
        }
        do {
            try archive.addEntry(
                with: mainFileName,
                type: .file,
                uncompressedSize: Int64(mscxData.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, mscxData.count)
                return mscxData.subdata(in: start..<end)
            }
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to add entry \(mainFileName): \(error)"
            )
        }
        guard let bytes = archive.data else {
            throw SheetMusicError.corruptedContainer(
                reason: "archive produced no bytes"
            )
        }
        return bytes
    }

    /// Package `.mscx` XML bytes and write the resulting `.mscz` to a file URL.
    public static func write(
        mscxData: Data,
        to url: URL,
        mainFileName: String = "score.mscx"
    ) throws {
        // Added in Task 7.
        fatalError("filled in Task 7")
    }

    private static func validate(mainFileName: String) throws {
        guard !mainFileName.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                reason: "mainFileName must not be empty"
            )
        }
        guard !mainFileName.contains("/") else {
            throw SheetMusicError.corruptedContainer(
                reason: "mainFileName must not contain '/': \(mainFileName)"
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run:
```bash
swift test --filter MSCZWriterTests
```
Expected: `roundTripDefaultMainName`, `roundTripCustomMainName`, `emptyMainNameThrows`, `nestedMainNameThrows` all pass.

- [ ] **Step 5: Run the full suite**

Run:
```bash
swift test
```
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZWriter.swift \
        Tests/SheetMusicTests/MSCZWriterTests.swift
git commit -m "mscx: add MSCZWriter.write(mscxData:) in-memory packaging"
```

---

## Task 7: `MSCZWriter.write(..., to url:)` URL overload

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCZWriter.swift`
- Modify: `Tests/SheetMusicTests/MSCZWriterTests.swift`

- [ ] **Step 1: Add failing tests**

Append inside `@Suite struct MSCZWriterTests`:

```swift
    @Test func writeToURLThenReadBack() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mscz-writer-test-\(UUID().uuidString).mscz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try MSCZWriter.write(mscxData: mscxData, to: tmp)
        let score = try MSCZReader.parse(contentsOf: tmp)
        let direct = try MSCXParser.parse(mscxData)
        #expect(score == direct)
    }

    @Test func writeToBadURLThrowsIOError() {
        let bogus = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.mscz")
        do {
            try MSCZWriter.write(mscxData: Data([0x3C, 0x78]), to: bogus)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .ioError(let u, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(u == bogus)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
swift test --filter MSCZWriterTests.writeToURLThenReadBack
```
Expected: FAIL via `fatalError` stub.

- [ ] **Step 3: Replace the stub with the real URL overload**

In `Sources/SheetMusicMSCX/MSCZWriter.swift`, replace the stub `write(mscxData:to:mainFileName:)` with:

```swift
    /// Package `.mscx` XML bytes and write the resulting `.mscz` to a file URL.
    public static func write(
        mscxData: Data,
        to url: URL,
        mainFileName: String = "score.mscx"
    ) throws {
        let bytes = try write(mscxData: mscxData, mainFileName: mainFileName)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
```

- [ ] **Step 4: Run tests; confirm pass**

Run:
```bash
swift test --filter MSCZWriterTests
swift test
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZWriter.swift \
        Tests/SheetMusicTests/MSCZWriterTests.swift
git commit -m "mscx: add MSCZWriter.write(mscxData:to:) URL overload"
```

---

## Task 8: `SheetMusic` umbrella façade additions

**Files:**
- Modify: `Sources/SheetMusic/SheetMusic.swift`
- Create: `Tests/SheetMusicTests/SheetMusicFacadeTests.swift`

- [ ] **Step 1: Write failing tests for every new façade method**

Create `Tests/SheetMusicTests/SheetMusicFacadeTests.swift`:

```swift
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct SheetMusicFacadeTests {
    @Test func loadScoreMSCZData() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let bytes = try Data(contentsOf: url)
        let score = try SheetMusic.loadScore(msczData: bytes)
        #expect(score.division == 480)
    }

    @Test func loadScoreMSCXURL() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let score = try SheetMusic.loadScore(mscxURL: url)
        #expect(score.parts.count == 1)
    }

    @Test func loadScoreMSCZURL() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let score = try SheetMusic.loadScore(msczURL: url)
        #expect(score.parts.count == 1)
    }

    @Test func saveMSCZDataRoundTrip() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let msczData = try SheetMusic.saveMSCZ(mscxData: mscxData)
        let score = try SheetMusic.loadScore(msczData: msczData)
        let direct = try SheetMusic.loadScore(mscxData: mscxData)
        #expect(score == direct)
    }

    @Test func saveMSCZURLRoundTrip() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("facade-test-\(UUID().uuidString).mscz")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try SheetMusic.saveMSCZ(mscxData: mscxData, to: tmp)
        let score = try SheetMusic.loadScore(msczURL: tmp)
        #expect(score.division == 480)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
swift test --filter SheetMusicFacadeTests
```
Expected: compile errors — new façade methods not defined.

- [ ] **Step 3: Add façade methods**

Replace `Sources/SheetMusic/SheetMusic.swift` with:

```swift
import Foundation
@_exported import SheetMusicCore
@_exported import SheetMusicMIDI
@_exported import SheetMusicMSCX

/// Top-level convenience façade for the SheetMusic family of libraries.
///
/// `import SheetMusic` re-exports `SheetMusicCore`, `SheetMusicMSCX`, and
/// `SheetMusicMIDI` so all public types of the typical "load mscx/mscz →
/// export MIDI" pipeline are visible without per-library imports.
public enum SheetMusic {
    /// Parse uncompressed `.mscx` bytes into a `Score`.
    public static func loadScore(mscxData: Data) throws -> Score {
        try MSCXParser.parse(mscxData)
    }

    /// Parse `.mscz` container bytes into a `Score` (main `.mscx` only).
    public static func loadScore(msczData: Data) throws -> Score {
        try MSCZReader.parse(msczData)
    }

    /// Read an `.mscx` file and parse into a `Score`.
    public static func loadScore(mscxURL: URL) throws -> Score {
        try MSCXParser.parse(contentsOf: mscxURL)
    }

    /// Read an `.mscz` file and parse its main `.mscx` into a `Score`.
    public static func loadScore(msczURL: URL) throws -> Score {
        try MSCZReader.parse(contentsOf: msczURL)
    }

    /// Package caller-supplied `.mscx` XML bytes into `.mscz` bytes.
    public static func saveMSCZ(mscxData: Data) throws -> Data {
        try MSCZWriter.write(mscxData: mscxData)
    }

    /// Package `.mscx` bytes and write the resulting `.mscz` to a file URL.
    public static func saveMSCZ(mscxData: Data, to url: URL) throws {
        try MSCZWriter.write(mscxData: mscxData, to: url)
    }

    /// Render a `Score` to SMF (Standard MIDI File) bytes.
    public static func exportMIDI(score: Score) throws -> Data {
        let midiFile = try MidiRenderer.render(score: score)
        return try MidiWriter.write(midiFile)
    }
}
```

- [ ] **Step 4: Run tests; confirm pass**

Run:
```bash
swift test --filter SheetMusicFacadeTests
swift test
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusic/SheetMusic.swift \
        Tests/SheetMusicTests/SheetMusicFacadeTests.swift
git commit -m "umbrella: expose mscz read, url overloads, saveMSCZ via SheetMusic"
```

---

## Task 9: Update `README.md` library table

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the library table**

Run:
```bash
grep -n "SheetMusicMSCX" README.md | head
```

Expected: a table row (or bullet) describing `SheetMusicMSCX` as a `.mscx` parser.

- [ ] **Step 2: Update the library-row description**

Edit `README.md`. In the `SheetMusicMSCX` row/bullet, change the description from a mscx-only phrasing to something equivalent to:

> MuseScore file I/O: `.mscx` parsing and `.mscz` read/write (main score only).

Preserve the surrounding table/bullet formatting exactly. Do not add new sections.

- [ ] **Step 3: Verify build still works (sanity, for linters)**

Run:
```bash
swift build
swiftlint --quiet Sources Tests || true
```
Expected: `swift build` succeeds; `swiftlint` 0 warnings (if installed — ignore if command missing).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: note MSCZ read/write support in SheetMusicMSCX row"
```

---

## Task 10: Final verification

**Files:** none.

- [ ] **Step 1: Full test run**

Run:
```bash
swift test 2>&1 | tail -30
```
Expected: `Test run with N tests passed after X seconds.` where N = 48 original + new = approximately 62. All green.

- [ ] **Step 2: Example app still builds**

Run:
```bash
cd Example && xcodegen generate
xcodebuild -project SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           build 2>&1 | tail -20
cd ..
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Linter clean**

Run:
```bash
swiftlint --quiet Sources Tests 2>&1 | tail -10
```
Expected: no output. (If `swiftlint` is not installed, skip this step.)

- [ ] **Step 4: Check git status is clean and log is coherent**

Run:
```bash
git status
git log --oneline -12
```

Expected: working tree clean; 9 new commits on top of the spec commit, each one message-scoped to a single task (error case, URL overload, fixture, reader data, reader url, writer data, writer url, umbrella, docs).

No additional commit here — the plan is complete.

---

## Self-review against the spec

| Spec requirement                                              | Task(s) |
| ------------------------------------------------------------- | ------- |
| `SheetMusicError.corruptedContainer(reason:)`                 | 1       |
| `SheetMusicError.ioError(url:underlying:)`                    | 1       |
| `MSCXParser.parse(contentsOf:)`                               | 2       |
| `midi01.mscz` fixture + LICENSE note                          | 3       |
| `MSCZReader.parse(_: Data)` with main-file fallback rule 1/2  | 4       |
| `MSCZReader.parse(contentsOf:)`                               | 5       |
| `MSCZWriter.write(mscxData:mainFileName:)`                    | 6       |
| `MSCZWriter.write(mscxData:to:mainFileName:)`                 | 7       |
| Umbrella: `loadScore(msczData:)`, `loadScore(mscxURL:)`, `loadScore(msczURL:)`, `saveMSCZ(mscxData:)`, `saveMSCZ(mscxData:to:)` | 8 |
| README library-table update                                   | 9       |
| `swift test` 100% green                                       | 10      |
| `swiftlint --quiet Sources Tests` 0 warnings                  | 9, 10   |
| Example app still builds                                      | 10      |
| No MuseScore code copied into `Sources/`                      | (design enforced — submodule read-only) |
| No auxiliary container resources read/written                 | (out of scope, enforced by API) |

Spec coverage: complete. No placeholders remain in task steps. Method
names (`parse`, `write`, `mainFileName`, `corruptedContainer`, `ioError`,
`loadScore(msczData:)` etc.) are consistent across tasks.
