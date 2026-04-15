# MuseScore 3 mscx Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept MuseScore 3-era `.mscx` files (MSC versions 300–399) in `MSCXParser`, producing the same `Score` structure the MuseScore 4 path already produces, while rejecting unsupported versions (1.x, 2.x, future 5.x+) with a dedicated error.

**Architecture:** Detect `<museScore version>` at parse entry, convert to an `MSCXVersion` integer (`major*100+minor`, matching MuseScore's own MSC numbering), thread an `MSCXParseContext` value through every decoder, and populate `Score.museScoreVersion`. Decoder bodies start v3/v4 identical — differences are discovered by structural parity tests on user-prepared v3↔v4 fixture pairs, and minimal `if context.version.isV3` branches are added only to the decoder(s) the tests flag.

**Tech Stack:** Swift 6.2, Swift Testing (`import Testing`), SwiftPM resources (`.process("Resources")`), Foundation `XMLParser` via the existing `XMLTreeParser` / `XMLNode` wrapper.

**Spec:** `docs/superpowers/specs/2026-04-15-musescore-3-mscx-support-design.md`

**Assumptions:**
- Plan lives on `main`. The MSCZ reading/writing work on `feature/mscz-reading-writing` is independent; this plan does NOT depend on MSCZ types (`MSCZReader` etc.) and will not reference them. MSCZ v3 parity is deferred to Task 13, which only becomes actionable after MSCZ merges.
- User will hand-prepare v3/v4 fixture pairs (the same small score exported from MuseScore 3 and MuseScore 4). Tasks 10–12 describe the reusable workflow; the literal fixture bytes and per-decoder branches cannot be pre-written.

---

## File Structure

**New files**
- `Sources/SheetMusicCore/MSCXVersion.swift` — value type wrapping the integer MSC version, with string parsing.
- `Sources/SheetMusicMSCX/MSCXParseContext.swift` — value type passed through all decoders (today: just `version`; room for `strict`, `warnings`, etc.).
- `Tests/SheetMusicTests/MSCXVersionTests.swift` — parsing + comparison coverage for the type.
- `Tests/SheetMusicTests/MSCXUnsupportedVersionTests.swift` — synthetic XML strings for 1.14 / 2.07 / 5.00 assert `.unsupportedVersion`.
- `Tests/SheetMusicTests/MSCXVersionParityTests.swift` — structural comparison of v3 vs v4 fixture pairs.
- `Tests/SheetMusicTests/Helpers/ScoreEquivalence.swift` — `expectStructurallyEqual(_:_:)` helper.

**Modified files**
- `Sources/SheetMusicCore/SheetMusicError.swift` — add `.unsupportedVersion(rawValue: Int)`.
- `Sources/SheetMusicCore/Score/Score.swift` — add `museScoreVersion: MSCXVersion` stored property.
- `Sources/SheetMusicMSCX/MSCXParser.swift` — detect version, reject unsupported, build context, dispatch.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift` — signature change + populate `museScoreVersion`.
- All other `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+<Type>.swift` (19 files) — signature change, pass context to sub-decoders.
- `Tests/SheetMusicTests/SheetMusicErrorTests.swift` — add a case exercising `.unsupportedVersion`.
- All test call sites doing `Bundle.module.url(forResource:withExtension:)` for fixtures — add `subdirectory: "v4"`.

**Fixture moves** (via `git mv`, preserving history)
- `Tests/SheetMusicTests/Resources/*.mscx` → `Tests/SheetMusicTests/Resources/v4/`
- `Tests/SheetMusicTests/Resources/*-ref.mid` → `Tests/SheetMusicTests/Resources/v4/`
- `Tests/SheetMusicTests/Resources/LICENSE` stays at `Resources/LICENSE` (covers both `v3/` and `v4/` subdirs per spec).
- New empty directory `Tests/SheetMusicTests/Resources/v3/` (holds a `.gitkeep` until user adds fixtures).

**Not created in this plan**
- `Sources/SheetMusicMSCX/Decoders/V3/` — per spec, defer until a decoder's v3 branch outgrows its parent file. YAGNI.

---

### Task 1: Add `MSCXVersion` value type

**Files:**
- Create: `Sources/SheetMusicCore/MSCXVersion.swift`
- Create: `Tests/SheetMusicTests/MSCXVersionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/MSCXVersionTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("MSCXVersion")
struct MSCXVersionTests {
    @Test("parses MuseScore 4.60 as 460")
    func parsesV460() {
        #expect(MSCXVersion.parse("4.60") == MSCXVersion(rawValue: 460))
    }

    @Test("parses MuseScore 3.01 as 301")
    func parsesV301() {
        #expect(MSCXVersion.parse("3.01") == MSCXVersion(rawValue: 301))
    }

    @Test("parses MuseScore 2.07 as 207")
    func parsesV207() {
        #expect(MSCXVersion.parse("2.07") == MSCXVersion(rawValue: 207))
    }

    @Test("parses bare major '4' as 400")
    func parsesBareMajor() {
        #expect(MSCXVersion.parse("4") == MSCXVersion(rawValue: 400))
    }

    @Test("rejects one-digit minor '3.1'")
    func rejectsOneDigitMinor() {
        #expect(MSCXVersion.parse("3.1") == nil)
    }

    @Test("rejects three-digit minor '3.100'")
    func rejectsThreeDigitMinor() {
        #expect(MSCXVersion.parse("3.100") == nil)
    }

    @Test("rejects non-numeric")
    func rejectsNonNumeric() {
        #expect(MSCXVersion.parse("") == nil)
        #expect(MSCXVersion.parse("abc") == nil)
        #expect(MSCXVersion.parse("3.") == nil)
        #expect(MSCXVersion.parse(".01") == nil)
    }

    @Test("isV3 covers 300..<400")
    func isV3Range() {
        #expect(MSCXVersion(rawValue: 300).isV3)
        #expect(MSCXVersion(rawValue: 302).isV3)
        #expect(MSCXVersion(rawValue: 399).isV3)
        #expect(!MSCXVersion(rawValue: 299).isV3)
        #expect(!MSCXVersion(rawValue: 400).isV3)
    }

    @Test("isV4 covers 400..<500")
    func isV4Range() {
        #expect(MSCXVersion(rawValue: 400).isV4)
        #expect(MSCXVersion(rawValue: 460).isV4)
        #expect(MSCXVersion(rawValue: 499).isV4)
        #expect(!MSCXVersion(rawValue: 500).isV4)
    }

    @Test("comparable")
    func comparable() {
        #expect(MSCXVersion(rawValue: 301) < MSCXVersion(rawValue: 460))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXVersion`
Expected: compile error — `MSCXVersion` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SheetMusicCore/MSCXVersion.swift`:

```swift
import Foundation

/// MuseScore MSC format version. Stored as `major*100 + minor` to match
/// MuseScore's own `Constants::MSC_VERSION` integer (e.g. `"4.60"` → 460,
/// `"3.01"` → 301). See `MuseScore/src/engraving/rw/rwregister.cpp` for
/// the canonical dispatch ranges.
public struct MSCXVersion: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Parses a `<museScore version="...">` attribute value.
    ///
    /// Accepted forms:
    ///   - `"<major>"`            — minor defaults to 0 (e.g. `"4"` → 400)
    ///   - `"<major>.<minor>"`    — minor must be exactly 2 digits, zero-padded,
    ///                              as MuseScore emits (`"4.60"`, `"3.01"`)
    ///
    /// One-digit or three-digit minors are rejected to avoid ambiguity
    /// (e.g. `"3.1"` could be 301 or 310). In practice MuseScore only
    /// writes two-digit minors, so this is strict by design.
    public static func parse(_ string: String) -> MSCXVersion? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let major = Int(parts[0]), major >= 0 else { return nil }
            return MSCXVersion(rawValue: major * 100)
        case 2:
            guard parts[1].count == 2,
                  let major = Int(parts[0]), major >= 0,
                  let minor = Int(parts[1]), minor >= 0 else {
                return nil
            }
            return MSCXVersion(rawValue: major * 100 + minor)
        default:
            return nil
        }
    }

    /// True for MuseScore 3 series (MSC 300–399).
    public var isV3: Bool { (300..<400).contains(rawValue) }

    /// True for MuseScore 4 series (MSC 400–499).
    public var isV4: Bool { (400..<500).contains(rawValue) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MSCXVersion`
Expected: PASS (11 checks across 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/MSCXVersion.swift Tests/SheetMusicTests/MSCXVersionTests.swift
git commit -m "core: add MSCXVersion value type for MSC version detection"
```

---

### Task 2: Add `SheetMusicError.unsupportedVersion`

**Files:**
- Modify: `Sources/SheetMusicCore/SheetMusicError.swift`
- Modify: `Tests/SheetMusicTests/SheetMusicErrorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/SheetMusicErrorTests.swift`:

```swift
@Test("unsupportedVersion case carries raw MSC integer")
func unsupportedVersionCarriesRawValue() {
    let err: SheetMusicError = .unsupportedVersion(rawValue: 207)
    guard case .unsupportedVersion(let raw) = err else {
        Issue.record("expected .unsupportedVersion")
        return
    }
    #expect(raw == 207)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SheetMusicError`
Expected: compile error — `unsupportedVersion` is not a member of `SheetMusicError`.

- [ ] **Step 3: Add the case**

Edit `Sources/SheetMusicCore/SheetMusicError.swift`, replacing the enum body:

```swift
public enum SheetMusicError: Error, Sendable {
    /// XML was syntactically invalid (could not be parsed by Foundation `XMLParser`).
    case invalidXML(underlying: Error)
    /// XML parsed but a required element/attribute was missing or malformed.
    case malformedScore(reason: String)
    /// A score element exists in the file but is not yet supported by the library.
    case unsupportedFeature(name: String, location: String?)
    /// `<museScore version>` is outside the supported MSC range (currently 3xx/4xx).
    /// `rawValue` is `major*100 + minor`; e.g. 207 for MuseScore 2.07, 500 for 5.x.
    case unsupportedVersion(rawValue: Int)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SheetMusicError`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/SheetMusicError.swift Tests/SheetMusicTests/SheetMusicErrorTests.swift
git commit -m "core: add SheetMusicError.unsupportedVersion for out-of-range MSC versions"
```

---

### Task 3: Add `MSCXParseContext`

**Files:**
- Create: `Sources/SheetMusicMSCX/MSCXParseContext.swift`

No tests yet — this type is thin and will be exercised by the parity/unsupported tests in later tasks. Creating a standalone test file for a one-field struct is overkill.

- [ ] **Step 1: Create the file**

Create `Sources/SheetMusicMSCX/MSCXParseContext.swift`:

```swift
import Foundation
import SheetMusicCore

/// Context threaded through every mscx decoder. Carries the detected MSC
/// version so individual decoders can branch on format differences
/// between MuseScore 3 and 4.
///
/// Kept as a value type so it composes under `Sendable` and remains cheap
/// to pass by copy. Future fields (strict mode, diagnostic collector,
/// base URL for resource resolution) should be added here with defaulted
/// initializer parameters to preserve source compatibility.
public struct MSCXParseContext: Sendable {
    public let version: MSCXVersion

    public init(version: MSCXVersion) {
        self.version = version
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: build succeeds. No new public API is called yet.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXParseContext.swift
git commit -m "mscx: add MSCXParseContext value type for version-aware decoding"
```

---

### Task 4: Move v4 fixtures into `Resources/v4/` subdirectory

This is a mechanical relocation that keeps existing tests green. `Bundle.module.url(forResource:withExtension:)` does not automatically recurse into subdirectories under SwiftPM's `.process` rule, so every call site must grow a `subdirectory: "v4"` argument.

**Files:**
- Move: all files under `Tests/SheetMusicTests/Resources/` except `LICENSE` → `Tests/SheetMusicTests/Resources/v4/`
- Create: `Tests/SheetMusicTests/Resources/v3/.gitkeep`
- Modify (test call sites): `Tests/SheetMusicTests/MSCXParserTests.swift`, `MidiRendererTests.swift`, `MidiExportTests.swift`, `SMFReaderTests.swift`

- [ ] **Step 1: Move the fixture files with git**

```bash
mkdir -p Tests/SheetMusicTests/Resources/v4 Tests/SheetMusicTests/Resources/v3
touch Tests/SheetMusicTests/Resources/v3/.gitkeep
git mv Tests/SheetMusicTests/Resources/*.mscx Tests/SheetMusicTests/Resources/v4/
git mv Tests/SheetMusicTests/Resources/*.mid Tests/SheetMusicTests/Resources/v4/
git add Tests/SheetMusicTests/Resources/v3/.gitkeep
```

Verify with `git status --short`: expect `R` (renamed) entries for every fixture file and one `A` for `.gitkeep`.

- [ ] **Step 2: Update `MSCXParserTests.swift`**

Edit `Tests/SheetMusicTests/MSCXParserTests.swift` at the fixture lookup. Change:

```swift
let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
```

to:

```swift
let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx", subdirectory: "v4"))
```

- [ ] **Step 3: Update `MidiRendererTests.swift`**

Same edit pattern — change the `Bundle.module.url(forResource: "midi01", withExtension: "mscx")` call to include `subdirectory: "v4"`.

- [ ] **Step 4: Update `SMFReaderTests.swift`**

Change:

```swift
let url = try #require(Bundle.module.url(forResource: "midi01-ref", withExtension: "mid"))
```

to:

```swift
let url = try #require(Bundle.module.url(forResource: "midi01-ref", withExtension: "mid", subdirectory: "v4"))
```

- [ ] **Step 5: Update `MidiExportTests.swift`**

This file uses a helper `private func loadCase(_ name: String)` (around line 29) that does two lookups. Update both:

```swift
let scoreURL = try #require(Bundle.module.url(forResource: name, withExtension: "mscx", subdirectory: "v4"))
let refURL = try #require(Bundle.module.url(forResource: "\(name)-ref", withExtension: "mid", subdirectory: "v4"))
```

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: all 48 existing tests pass. A failure on fixture lookup means a call site was missed — grep for `Bundle.module.url(forResource:` to find any stragglers.

- [ ] **Step 7: Commit**

```bash
git add Tests/SheetMusicTests
git commit -m "tests: relocate v4 fixtures under Resources/v4/, add v3/ placeholder"
```

---

### Task 5: Add `museScoreVersion` to `Score` and thread context through `Score.decode`

This is the central signature change. It touches every decoder because `Score.decode` calls `Part.decode` and `StaffContent.decode`, which call `Measure.decode`, and so on down to the leaves. Rather than splitting across many tasks, treat this as one atomic "add the parameter everywhere" commit — the change is entirely mechanical (add `context: MSCXParseContext` param, pass it to every sub-`decode` call). Parser entry is wired in the next task; for now `MSCXParser.parse` is adjusted to construct a stub `MSCXParseContext(version: MSCXVersion(rawValue: 460))` so existing fixtures keep working.

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score.swift` (add stored property)
- Modify: `Sources/SheetMusicMSCX/MSCXParser.swift` (temporary stub context — replaced in Task 6)
- Modify: every `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+*.swift` (20 files)

- [ ] **Step 1: Add `museScoreVersion` to `Score`**

Edit `Sources/SheetMusicCore/Score/Score.swift`:

```swift
import Foundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var museScoreVersion: MSCXVersion
    public var division: Int
    public var parts: [Part]
    public var staves: [StaffContent]
    public var metaTags: [String: String]

    public init(
        museScoreVersion: MSCXVersion,
        division: Int,
        parts: [Part] = [],
        staves: [StaffContent] = [],
        metaTags: [String: String] = [:]
    ) {
        self.museScoreVersion = museScoreVersion
        self.division = division
        self.parts = parts
        self.staves = staves
        self.metaTags = metaTags
    }
}
```

- [ ] **Step 2: Verify the build breaks exactly where expected**

Run: `swift build`
Expected: compile errors in `MSCXDecoder+Score.swift` (missing `museScoreVersion` argument) and in any test that constructs `Score` directly. Note the failing locations — all will be fixed below.

- [ ] **Step 3: Update `MSCXDecoder+Score.swift`**

Edit `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift`:

```swift
import Foundation
import SheetMusicCore

extension Score {
    static func decode(_ root: XMLNode, context: MSCXParseContext) throws -> Score {
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(reason: "root is <\(root.name)>, expected <museScore>")
        }
        guard let scoreNode = root.first("Score") else {
            throw SheetMusicError.malformedScore(reason: "missing <Score>")
        }
        guard let divisionText = scoreNode.first("Division")?.text, let division = Int(divisionText) else {
            throw SheetMusicError.malformedScore(reason: "missing <Division>")
        }
        let parts = try scoreNode.all("Part").map { try Part.decode($0, context: context) }
        let staves = try scoreNode.all("Staff").map { try StaffContent.decode($0, context: context) }
        var metaTags: [String: String] = [:]
        for tag in scoreNode.all("metaTag") {
            if let name = tag.attributes["name"] {
                metaTags[name] = tag.text
            }
        }
        return Score(
            museScoreVersion: context.version,
            division: division,
            parts: parts,
            staves: staves,
            metaTags: metaTags
        )
    }
}
```

- [ ] **Step 4: Update every other decoder signature**

For each file in `Sources/SheetMusicMSCX/Decoders/` other than `MSCXDecoder+Score.swift`, apply the uniform rewrite:

Old:
```swift
static func decode(_ node: XMLNode) throws -> Self { ... }
```

New:
```swift
static func decode(_ node: XMLNode, context: MSCXParseContext) throws -> Self { ... }
```

And inside each body, every call to a sub-`decode` gains `context: context`. Examples per file:

**`MSCXDecoder+Voice.swift`** — the body's switch dispatches to 10 sub-decoders. Update each call:
```swift
case "Chord":
    elements.append(.chord(try Chord.decode(child, context: context)))
case "Rest":
    elements.append(.rest(try Rest.decode(child, context: context)))
case "KeySig":
    elements.append(.keySignature(try KeySignature.decode(child, context: context)))
case "TimeSig":
    elements.append(.timeSignature(try TimeSignature.decode(child, context: context)))
case "Clef":
    elements.append(.clef(try Clef.decode(child, context: context)))
case "BarLine":
    elements.append(.barLine(try BarLine.decode(child, context: context)))
case "Tempo":
    elements.append(.tempo(try Tempo.decode(child, context: context)))
case "Dynamic":
    elements.append(.dynamic(try Dynamic.decode(child, context: context)))
case "Spanner":
    elements.append(.spanner(try Spanner.decode(child, context: context)))
case "MeasureRepeat":
    elements.append(.measureRepeat(try MeasureRepeat.decode(child, context: context)))
```

**`MSCXDecoder+Part.swift`** — calls `Instrument.decode` and `StaffDeclaration.decode`. Thread `context:` through both.

**`MSCXDecoder+StaffContent.swift`** — calls `Measure.decode`. Thread `context:`.

**`MSCXDecoder+Measure.swift`** — calls `Voice.decode` (and any other sub-decoder). Thread `context:`.

**`MSCXDecoder+Chord.swift`** — calls `Note.decode`. Thread `context:`.

**`MSCXDecoder+Instrument.swift`** — calls `InstrumentChannel.decode` and `InstrumentArticulation.decode`. Thread `context:`.

Leaf decoders (`MSCXDecoder+Note.swift`, `+Clef.swift`, `+KeySignature.swift`, `+TimeSignature.swift`, `+Tempo.swift`, `+Dynamic.swift`, `+Spanner.swift`, `+BarLine.swift`, `+Rest.swift`, `+MeasureRepeat.swift`, `+InstrumentChannel.swift`, `+InstrumentArticulation.swift`, `+StaffDeclaration.swift`) — add the `context: MSCXParseContext` parameter and accept that it is unused. Do not add `_ = context` — Swift accepts unused parameters silently.

Work through the files with `grep -l 'static func decode' Sources/SheetMusicMSCX/Decoders/` and apply to each.

- [ ] **Step 5: Temporarily stub context in `MSCXParser`**

Edit `Sources/SheetMusicMSCX/MSCXParser.swift`:

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
        // TEMPORARY: real version detection is wired in the next commit.
        let context = MSCXParseContext(version: MSCXVersion(rawValue: 460))
        return try Score.decode(root, context: context)
    }
}
```

(The `TEMPORARY` comment is fine — it lives for exactly one commit and is replaced in Task 6.)

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: all tests pass. If any still fail to compile, it is almost always a sub-`decode` call that was missed. `grep -rn 'try [A-Z][A-Za-z]*\.decode(' Sources/SheetMusicMSCX/Decoders/ | grep -v 'context:'` will surface any stragglers.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicCore/Score/Score.swift Sources/SheetMusicMSCX
git commit -m "mscx: thread MSCXParseContext through all decoders, publish Score.museScoreVersion"
```

---

### Task 6: Wire real version detection in `MSCXParser`

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCXParser.swift`

- [ ] **Step 1: Replace the stub context with real detection**

Edit `Sources/SheetMusicMSCX/MSCXParser.swift`:

```swift
import Foundation
import SheetMusicCore

/// Public façade that turns mscx XML bytes into a `Score`.
public enum MSCXParser {
    /// Parse uncompressed `.mscx` XML bytes into an in-memory `Score`.
    ///
    /// Supported formats: MuseScore 3.x (MSC 300–399) and 4.x (MSC 400–499).
    /// Earlier and later formats raise `SheetMusicError.unsupportedVersion`.
    ///
    /// - Throws:
    ///   - `SheetMusicError.invalidXML` for ill-formed XML
    ///   - `SheetMusicError.malformedScore` for a missing root, missing
    ///     `version` attribute, or unparseable version string
    ///   - `SheetMusicError.unsupportedVersion` for 1.x, 2.x, or 5.x+
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(
                reason: "root is <\(root.name)>, expected <museScore>")
        }
        guard let versionString = root.attributes["version"] else {
            throw SheetMusicError.malformedScore(
                reason: "<museScore> missing version attribute")
        }
        guard let version = MSCXVersion.parse(versionString) else {
            throw SheetMusicError.malformedScore(
                reason: "unparseable museScore version '\(versionString)'")
        }
        guard version.isV3 || version.isV4 else {
            throw SheetMusicError.unsupportedVersion(rawValue: version.rawValue)
        }
        return try Score.decode(root, context: MSCXParseContext(version: version))
    }
}
```

- [ ] **Step 2: Run the full suite**

Run: `swift test`
Expected: all tests pass — existing v4 fixtures declare `<museScore version="4.60">` which parses to 460 and passes `isV4`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXParser.swift
git commit -m "mscx: detect museScore version attribute and dispatch through MSCXParseContext"
```

---

### Task 7: Add `MSCXUnsupportedVersionTests`

**Files:**
- Create: `Tests/SheetMusicTests/MSCXUnsupportedVersionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/MSCXUnsupportedVersionTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Foundation
import Testing

@Suite("MSCXParser unsupported versions")
struct MSCXUnsupportedVersionTests {
    private func xml(version: String) -> Data {
        let s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="\(version)">
          <Score>
            <Division>480</Division>
          </Score>
        </museScore>
        """
        return Data(s.utf8)
    }

    private func assertUnsupportedVersion(_ version: String, expectedRaw: Int) {
        do {
            _ = try MSCXParser.parse(xml(version: version))
            Issue.record("expected throw for version \(version)")
        } catch SheetMusicError.unsupportedVersion(let raw) {
            #expect(raw == expectedRaw)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func assertMalformed(_ data: Data) {
        do {
            _ = try MSCXParser.parse(data)
            Issue.record("expected malformedScore throw")
        } catch SheetMusicError.malformedScore {
            // ok
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("rejects MuseScore 1.14 with unsupportedVersion(114)")
    func rejectsV114() { assertUnsupportedVersion("1.14", expectedRaw: 114) }

    @Test("rejects MuseScore 2.07 with unsupportedVersion(207)")
    func rejectsV207() { assertUnsupportedVersion("2.07", expectedRaw: 207) }

    @Test("rejects future MuseScore 5.00 with unsupportedVersion(500)")
    func rejectsV500() { assertUnsupportedVersion("5.00", expectedRaw: 500) }

    @Test("missing version attribute raises malformedScore")
    func missingVersionAttribute() {
        let s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore><Score><Division>480</Division></Score></museScore>
        """
        assertMalformed(Data(s.utf8))
    }

    @Test("unparseable version raises malformedScore")
    func unparseableVersion() {
        assertMalformed(xml(version: "abc"))
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter MSCXUnsupportedVersion`
Expected: all 5 tests PASS — the plumbing is already in place from Task 6.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/MSCXUnsupportedVersionTests.swift
git commit -m "tests: reject MSC 1.x/2.x/5.x with SheetMusicError.unsupportedVersion"
```

---

### Task 8: Add `expectStructurallyEqual` test helper

The parity suite (next task) needs a comparison that ignores fields that legitimately differ between v3 and v4 (`museScoreVersion` by definition; `metaTags` because MuseScore 3 emits extra entries like `programVersion` / `programRevision` while MuseScore 4 does not). All other fields must match exactly.

**Files:**
- Create: `Tests/SheetMusicTests/Helpers/ScoreEquivalence.swift`

- [ ] **Step 1: Write the helper**

Create `Tests/SheetMusicTests/Helpers/ScoreEquivalence.swift`:

```swift
@testable import SheetMusicCore
import Testing

/// Asserts two `Score`s are structurally equivalent, ignoring fields that
/// are expected to diverge between MSC versions:
///   - `museScoreVersion` — different by construction
///   - `metaTags`         — MuseScore 3 emits extra tags MuseScore 4 doesn't
///
/// All musical content (`division`, `parts`, `staves`) must match exactly.
func expectStructurallyEqual(
    _ actual: Score,
    _ expected: Score,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        actual.division == expected.division,
        "division mismatch: got \(actual.division), expected \(expected.division)",
        sourceLocation: sourceLocation
    )
    #expect(
        actual.parts == expected.parts,
        "parts mismatch",
        sourceLocation: sourceLocation
    )
    #expect(
        actual.staves == expected.staves,
        "staves mismatch",
        sourceLocation: sourceLocation
    )
}
```

- [ ] **Step 2: Verify build**

Run: `swift build --target SheetMusicTests`
Expected: succeeds. No test calls the helper yet, but the file must compile.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/Helpers/ScoreEquivalence.swift
git commit -m "tests: add expectStructurallyEqual helper for cross-version Score comparison"
```

---

### Task 9: Add `MSCXVersionParityTests` skeleton

This task adds the test class. The actual fixture pairs are contributed by the user in Task 10 (per-pair) — the skeleton here compiles with no fixtures and adds tests one per fixture pair as they arrive.

**Files:**
- Create: `Tests/SheetMusicTests/MSCXVersionParityTests.swift`

- [ ] **Step 1: Write the skeleton**

Create `Tests/SheetMusicTests/MSCXVersionParityTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Foundation
import Testing

/// Structural parity between MuseScore 3 and MuseScore 4 exports of the
/// same score. Fixtures are hand-prepared pairs: `Resources/v3/<name>.mscx`
/// and `Resources/v4/<name>.mscx`, same musical content.
@Suite("MSCX v3/v4 parity")
struct MSCXVersionParityTests {
    private func parse(_ name: String, subdirectory: String) throws -> Score {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "mscx",
                subdirectory: subdirectory
            ),
            "missing fixture \(subdirectory)/\(name).mscx"
        )
        let data = try Data(contentsOf: url)
        return try MSCXParser.parse(data)
    }

    private func parity(_ name: String) throws {
        let v3 = try parse(name, subdirectory: "v3")
        let v4 = try parse(name, subdirectory: "v4")
        #expect(v3.museScoreVersion.isV3, "v3 fixture did not parse as MSC 3xx")
        #expect(v4.museScoreVersion.isV4, "v4 fixture did not parse as MSC 4xx")
        expectStructurallyEqual(v3, v4)
    }

    // Per-fixture tests are added below as user provides fixture pairs.
    // Template (uncomment and rename when a pair lands in Resources/v3/ and Resources/v4/):
    //
    // @Test("<fixtureName>")
    // func <fixtureName>() throws { try parity("<fixtureName>") }
}
```

- [ ] **Step 2: Verify build**

Run: `swift test --filter MSCXVersionParityTests`
Expected: suite compiles and reports zero tests (all test methods are commented out). No failure — an empty suite is valid.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/MSCXVersionParityTests.swift
git commit -m "tests: scaffold MSCXVersionParityTests for v3/v4 fixture comparison"
```

---

### Task 10: Per-fixture v3/v4 parity workflow (iterative, user-dependent)

This task is a **template loop** repeated for each fixture pair the user provides. It is not a single commit — each iteration lands its own commit (or small cluster of commits when a decoder branch is needed).

**Prerequisite per iteration:**
- User exports the same small score from MuseScore 3 as `Resources/v3/<name>.mscx` and from MuseScore 4 as `Resources/v4/<name>.mscx`. The musical content must match bar-for-bar; only the file format differs.

**Per-fixture workflow:**

- [ ] **Step A: Confirm fixtures are in place**

Run: `ls Tests/SheetMusicTests/Resources/v3/<name>.mscx Tests/SheetMusicTests/Resources/v4/<name>.mscx`
Expected: both files exist.

- [ ] **Step B: Enable the parity test**

Edit `Tests/SheetMusicTests/MSCXVersionParityTests.swift` and uncomment / add:

```swift
@Test("<name>")
func <name>() throws { try parity("<name>") }
```

(Replace `<name>` with the fixture stem — e.g. `simpleMelody`.)

- [ ] **Step C: Run the test**

Run: `swift test --filter MSCXVersionParityTests/<name>`

Two outcomes:

1. **Test passes.** The permissive voice decoder absorbed all v3 differences; no code change needed. Go to Step E.
2. **Test fails.** The failure message will name the field that diverges (`division mismatch`, `parts mismatch`, `staves mismatch`). Go to Step D.

- [ ] **Step D: Diagnose and add a minimal v3 branch**

Narrow the divergence by comparing the two XML files side by side (`diff -u Resources/v3/<name>.mscx Resources/v4/<name>.mscx`). Typical patterns and their fixes:

- **v3 uses a renamed tag** (e.g. `<Spatium>` vs `<spatium>`, or a different attribute name). Add a one-line branch inside the relevant leaf decoder:
  ```swift
  let tagName = context.version.isV3 ? "OldName" : "NewName"
  let n = node.first(tagName)
  ```
  Keep the branch scoped to the single lookup that differs.

- **v3 represents a sub-element with different children** (e.g. `<Channel>` nesting inside `<Instrument>`). If the difference is ≤ 10 lines within one decoder, inline it:
  ```swift
  if context.version.isV3 {
      // v3 path
  } else {
      // v4 path (existing body)
  }
  ```
  If the v3 path exceeds ~30 lines of logic distinct from v4, create `Sources/SheetMusicMSCX/Decoders/V3/MSCXDecoder+<Type>.swift` and forward from the main decoder:
  ```swift
  static func decode(_ node: XMLNode, context: MSCXParseContext) throws -> Self {
      if context.version.isV3 {
          return try decodeV3(node, context: context)
      }
      // existing v4 body
  }
  ```

- **v3 emits an element v4 never emits** (e.g. `<LayerTag>` under `<Score>`). If it appears in a location where the current decoder uses an explicit `first("...")` or `all("...")` lookup, no code change needed — the tag is simply ignored. Only act if parsing actually fails.

Re-run the test after each change.

- [ ] **Step E: Commit the iteration**

```bash
git add Tests/SheetMusicTests/Resources/v3/<name>.mscx \
        Tests/SheetMusicTests/Resources/v4/<name>.mscx \
        Tests/SheetMusicTests/MSCXVersionParityTests.swift \
        Sources/SheetMusicMSCX
git commit -m "mscx: cover <name> v3/v4 parity"
```

If a v3 decoder branch was added, include it in the same commit so each fixture's acceptance is one reviewable unit.

- [ ] **Step F: Run the full suite**

Run: `swift test`
Expected: all suites green, including every previously enabled parity test. If an earlier parity test regressed, the v3 branch added this iteration was too broad — narrow it.

Repeat Steps A–F for each additional fixture pair.

---

### Task 11: (deferred) MS3 `.mscz` parity test

Activate only once `feature/mscz-reading-writing` has merged to `main` (the branch that adds `MSCZReader.parse(_:)`). Until then, skip.

**Prerequisite:** `MSCZReader` public API is available on `main`.

**Files:**
- Add: `Tests/SheetMusicTests/Resources/v3/<name>.mscz` and `Tests/SheetMusicTests/Resources/v4/<name>.mscz` (user-provided ZIPs of an already-passing parity fixture)
- Modify: `Tests/SheetMusicTests/MSCXVersionParityTests.swift` (add an `.mscz`-path variant)

- [ ] **Step 1: Add the .mscz variant test**

Extend `MSCXVersionParityTests` with a helper and a `@Test`:

```swift
private func parseMSCZ(_ name: String, subdirectory: String) throws -> Score {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "mscz",
            subdirectory: subdirectory
        ),
        "missing fixture \(subdirectory)/\(name).mscz"
    )
    return try MSCZReader.parse(Data(contentsOf: url))
}

@Test("<name> .mscz round-trip")
func <name>MSCZ() throws {
    let v3 = try parseMSCZ("<name>", subdirectory: "v3")
    let v4 = try parseMSCZ("<name>", subdirectory: "v4")
    #expect(v3.museScoreVersion.isV3)
    #expect(v4.museScoreVersion.isV4)
    expectStructurallyEqual(v3, v4)
}
```

- [ ] **Step 2: Run**

Run: `swift test --filter MSCXVersionParityTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests
git commit -m "tests: cover v3 .mscz round-trip through MSCZReader"
```

---

## Self-Review Notes

- **Spec coverage checked**: MSCXVersion (Task 1), MSCXParseContext (Task 3), unsupportedVersion error (Task 2 + Task 7), Score.museScoreVersion (Task 5), MSCXParser version dispatch (Task 6), decoder signature migration (Task 5), fixture `v3/` `v4/` layout (Task 4), parity test harness (Tasks 8–9), per-fixture workflow (Task 10), MSCZ v3 integration (Task 11). Every spec section maps to a task.
- **Placeholder scan**: no TBDs; the two iterative tasks (10, 11) are iterative by design (per-fixture / deferred-until-branch-lands) and provide literal commands rather than hand-wave "add tests".
- **Type consistency**: `MSCXVersion` / `MSCXParseContext` / `Score.museScoreVersion` use the same names across all tasks. `isV3` / `isV4` booleans are defined in Task 1 and used in Tasks 6, 9, 10.

---

## Execution Options

**Plan complete.** Saved to `docs/superpowers/plans/2026-04-15-musescore-3-mscx-support.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks. Matches the clean-room nature of the mechanical signature changes in Task 5.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
