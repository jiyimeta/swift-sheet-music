# MSCX Export — MuseScore 3 Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `MSCXEncoderOptions.targetVersion = .v3` path to the existing MSCX encoder so a MIDI-imported `Score` round-trips into a `.mscx` / `.mscz` that opens cleanly in MuseScore 3.6.2, while the default MS4 path stays byte-identical.

**Architecture:** Introduce `MSCXVersion` (in `SheetMusicCore`) and `MSCXEncoderOptions` (in `SheetMusicMSCX`). Add `encode(_:options:)` overloads on `MSCXEncoder`, `MSCZWriter`, and `SheetMusic`. Thread `options` through the encoder call graph as a defaulted parameter on every per-type `encode(...)` helper that needs a v3 branch. Each wire-form delta lives in its existing `MSCXEncoder+<Type>.swift` file, gated on `options.targetVersion == .v3`.

**Tech Stack:** Swift Package Manager, Swift Testing (`@Test`/`#expect`), `XMLTreeNode` / `XMLTreeSerializer` from `SheetMusicXMLTools`, ZIPFoundation for `.mscz`.

---

## Reference

Implementing the design recorded in `docs/superpowers/specs/2026-05-08-mscx-export-ms3-design.md`. Read §A–§G of that spec before starting — each task below cites the section it implements. The "canonical" MS3 sample lives at `~/Desktop/test-min.mscx` (not checked in).

## File Structure

**Create:**
- `Sources/SheetMusicCore/MSCXVersion.swift` — `MSCXVersion` enum (v3 / v4).
- `Sources/SheetMusicMSCX/MSCXEncoderOptions.swift` — `MSCXEncoderOptions` struct.
- `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift` — all new MS3 wire-form tests.

**Modify:**
- `Sources/SheetMusicMSCX/MSCXEncoder.swift` — add `encode(_:options:)`.
- `Sources/SheetMusicMSCX/MSCZWriter.swift` — add `write(score:options:…)` overloads.
- `Sources/SheetMusic/SheetMusic.swift` — add façade options overloads.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift` — §A.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift` — §B.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift` — §C.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift` — §E.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift` — §F.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` — §G stem.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift` — §G head.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` — thread `options` + drop initial-zero KeySig.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift` — thread `options` + carry "is first measure of staff" flag.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift` — thread `options`.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift` — thread `options` + signal "first measure".
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift` — thread `options` so the per-Channel call can pass it.
- `README.md` — one line about `MSCXEncoderOptions`.

---

## Task 1: Add `MSCXVersion` enum

**Files:**
- Create: `Sources/SheetMusicCore/MSCXVersion.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift` (create the file with this initial content):

```swift
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 target")
struct MSCXEncoderMS3Tests {
    @Test("MSCXVersion has v3 and v4 cases")
    func mscxVersionCases() {
        let v3: MSCXVersion = .v3
        let v4: MSCXVersion = .v4
        #expect(v3 != v4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXEncoderMS3Tests/mscxVersionCases`
Expected: FAIL with "cannot find 'MSCXVersion' in scope".

- [ ] **Step 3: Create `MSCXVersion`**

Write `Sources/SheetMusicCore/MSCXVersion.swift`:

```swift
import Foundation

/// MuseScore wire-format major version targeted by the MSCX encoder
/// and recognised by the MSCX decoder.
///
/// `v4` is the current default. `v3` covers MuseScore 3.x readers
/// (programVersion 3.6.2 in `~/Desktop/test-min.mscx`).
public enum MSCXVersion: Sendable, Hashable {
    /// MuseScore 3.x — `<museScore version="3.02">`, programVersion 3.6.2.
    case v3
    /// MuseScore 4.x — `<museScore version="4.60">`.
    case v4
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MSCXEncoderMS3Tests/mscxVersionCases`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/MSCXVersion.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(core): add MSCXVersion enum for encoder targeting"
```

---

## Task 2: Add `MSCXEncoderOptions`

**Files:**
- Create: `Sources/SheetMusicMSCX/MSCXEncoderOptions.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift` inside the suite:

```swift
@Test("MSCXEncoderOptions defaults to v4")
func optionsDefaultsToV4() {
    let opts = MSCXEncoderOptions()
    #expect(opts.targetVersion == .v4)
}

@Test("MSCXEncoderOptions accepts v3")
func optionsAcceptsV3() {
    let opts = MSCXEncoderOptions(targetVersion: .v3)
    #expect(opts.targetVersion == .v3)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXEncoderMS3Tests/optionsDefaultsToV4`
Expected: FAIL with "cannot find 'MSCXEncoderOptions' in scope".

- [ ] **Step 3: Create `MSCXEncoderOptions`**

Write `Sources/SheetMusicMSCX/MSCXEncoderOptions.swift`:

```swift
import Foundation
import SheetMusicCore

/// Knobs for `MSCXEncoder.encode(_:options:)`.
///
/// `targetVersion` selects which MuseScore wire-form variant the
/// encoder produces. Defaults to `.v4` so existing call sites that
/// use the zero-arg `encode(_:)` overload retain MS4 output.
public struct MSCXEncoderOptions: Sendable {
    public var targetVersion: MSCXVersion

    public init(targetVersion: MSCXVersion = .v4) {
        self.targetVersion = targetVersion
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: 3 tests PASS (v3/v4 cases, defaults to v4, accepts v3).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXEncoderOptions.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): add MSCXEncoderOptions targetVersion knob"
```

---

## Task 3: Add `encode(_:options:)` plumbing — façade overloads

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCXEncoder.swift`
- Modify: `Sources/SheetMusicMSCX/MSCZWriter.swift`
- Modify: `Sources/SheetMusic/SheetMusic.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

This task wires the public API surface and threads `options` to the top-level Score encode. Per-type extension threading happens in Task 4. The v4 path is unchanged; the v3 path emits identical output to v4 (no version-specific branches yet) so existing tests stay green.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift`:

```swift
@Test("MSCXEncoder.encode(_:options:) v4 default matches zero-arg")
func encodeOptionsV4DefaultMatchesLegacy() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let legacy = try MSCXEncoder.encode(score)
    let options = try MSCXEncoder.encode(score, options: .init())
    #expect(legacy == options)
}

@Test("MSCZWriter.write(score:options:) round-trips score")
func msczWriteOptionsRoundTrips() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCZWriter.write(score: score, options: .init())
    let reparsed = try MSCZReader.parse(bytes)
    #expect(reparsed.parts.count == score.parts.count)
}

@Test("SheetMusic.exportMSCZ accepts options")
func sheetMusicExportMSCZAcceptsOptions() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ms3-export-\(UUID().uuidString).mscz")
    defer { try? FileManager.default.removeItem(at: url) }
    try SheetMusic.exportMSCZ(score, options: .init(targetVersion: .v3), to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: 3 new tests FAIL with "incorrect argument label 'options:'" or similar.

- [ ] **Step 3: Add `encode(_:options:)` to `MSCXEncoder`**

Replace `Sources/SheetMusicMSCX/MSCXEncoder.swift` body (keep the file header doc comment) with:

```swift
public enum MSCXEncoder {
    /// Serialize a `Score` to `.mscx` XML bytes (default MuseScore 4 target).
    public static func encode(_ score: Score) throws -> Data {
        try encode(score, options: .init())
    }

    /// Serialize a `Score` to `.mscx` XML bytes with the given options.
    public static func encode(
        _ score: Score, options: MSCXEncoderOptions
    ) throws -> Data {
        let root = try score.encode(options: options)
        return XMLTreeSerializer.serialize(root)
    }

    /// Serialize a `Score` and write the resulting `.mscx` to a file URL.
    public static func encode(_ score: Score, to url: URL) throws {
        let bytes = try encode(score)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    /// Serialize a `Score` with the given options and write the
    /// resulting `.mscx` to a file URL.
    public static func encode(
        _ score: Score, options: MSCXEncoderOptions, to url: URL
    ) throws {
        let bytes = try encode(score, options: options)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
}
```

- [ ] **Step 4: Update `Score.encode()` to accept `options`**

Replace the `encode()` signature in `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift` with:

```swift
extension Score {
    /// Build the `<museScore><Score>…</Score></museScore>` root.
    func encode(options: MSCXEncoderOptions = .init()) throws -> XMLTreeNode {
        // existing body unchanged for now; threading happens in later tasks.
        var scoreChildren: [XMLTreeNode] = []
        scoreChildren.append(XMLTreeNode(
            name: "Division", text: String(division)
        ))
        scoreChildren.append(style.encode())
        for key in metaTags.keys.sorted() {
            scoreChildren.append(XMLTreeNode(
                name: "metaTag",
                attributes: ["name": key],
                text: metaTags[key] ?? ""
            ))
        }

        var allStaffIDs: [(part: Part, partID: String, ids: [String])] = []
        var nextStaffID = 1
        for (partIndex, part) in parts.enumerated() {
            let partID = String(partIndex + 1)
            let ids = part.staves.indices.map { _ -> String in
                let id = String(nextStaffID)
                nextStaffID += 1
                return id
            }
            allStaffIDs.append((part, partID, ids))
        }
        for (part, partID, ids) in allStaffIDs {
            scoreChildren.append(
                part.encodeDeclaration(partID: partID, staffIDs: ids))
        }
        var titleFrameSlot = titleFrame
        for (part, _, ids) in allStaffIDs {
            for (staff, id) in zip(part.staves, ids) {
                let frame = titleFrameSlot
                titleFrameSlot = nil
                try scoreChildren.append(
                    staff.encodeTopLevel(staffID: id, titleFrame: frame)
                )
            }
        }

        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": "4.60"],
            children: [
                XMLTreeNode(name: "Score", children: scoreChildren),
            ]
        )
    }
}
```

(The body is identical to the existing one — only the signature changes. v3 branches arrive in Task 5.)

- [ ] **Step 5: Add `write(score:options:…)` overloads on `MSCZWriter`**

In `Sources/SheetMusicMSCX/MSCZWriter.swift`, add directly after the existing `write(score:to:mainFileName:)` definition (inside the `enum MSCZWriter`):

```swift
    /// Serialize a `Score` with options and package as `.mscz` bytes.
    public static func write(
        score: Score, options: MSCXEncoderOptions,
        mainFileName: String = "score.mscx"
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score, options: options)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    /// Serialize a `Score` with options and write the resulting
    /// `.mscz` to a file URL.
    public static func write(
        score: Score, options: MSCXEncoderOptions, to url: URL,
        mainFileName: String = "score.mscx"
    ) throws {
        let bytes = try write(
            score: score, options: options, mainFileName: mainFileName
        )
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
```

- [ ] **Step 6: Add façade overloads on `SheetMusic`**

In `Sources/SheetMusic/SheetMusic.swift`, add after the existing `exportMSCZ(_:to:)`:

```swift
    /// Serialize a `Score` to `.mscx` with the given options and
    /// write the result to a file URL.
    public static func exportMSCX(
        _ score: Score, options: MSCXEncoderOptions, to url: URL
    ) throws {
        try MSCXEncoder.encode(score, options: options, to: url)
    }

    /// Serialize a `Score` to `.mscz` with the given options and
    /// write the result to a file URL.
    public static func exportMSCZ(
        _ score: Score, options: MSCXEncoderOptions, to url: URL
    ) throws {
        try MSCZWriter.write(score: score, options: options, to: url)
    }
```

- [ ] **Step 7: Run tests to verify the new façade tests pass**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: All Task 1–3 tests PASS.

Run: `swift test`
Expected: All existing tests still PASS (716+).

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXEncoder.swift \
        Sources/SheetMusicMSCX/MSCZWriter.swift \
        Sources/SheetMusic/SheetMusic.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift \
        Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): add encode(_:options:) and MSCZ façade overloads"
```

---

## Task 4: Thread `options` through encoder call graph

Pure plumbing: add `options: MSCXEncoderOptions = .init()` to every encoder helper that will need a v3 branch (Style, Part, Staff, Measure, Voice, Chord, Note, KeySignature, Spanner, Instrument, InstrumentChannel). No behaviour change — the parameter is unused everywhere except being forwarded. This isolates "wire the parameter" from "use the parameter" so the compile lands cleanly.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

- [ ] **Step 1: Add `options` to each helper signature**

For every file above, add `options: MSCXEncoderOptions = .init()` as the last parameter on `encode(...)` (and `encodeAsChord` / `encodeAsRest` / `encodeDeclaration` / `encodeTopLevel` where those exist), and forward it to nested calls. The existing default-argument means existing internal call sites don't need updates. Concrete edits:

`MSCXEncoder+Style.swift`:

```swift
extension ScoreStyle {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        // body unchanged for this task
    }
}
```

`MSCXEncoder+Part.swift`:

```swift
extension Part {
    func encodeDeclaration(
        partID: String,
        staffIDs: [String],
        options: MSCXEncoderOptions = .init()
    ) -> XMLTreeNode {
        // body unchanged; pass `options` to instrument.encode(options:)
        // and staff.encodeDeclaration(staffID:options:)
    }
}
```

Update the body so:

```swift
        for (staff, id) in zip(staves, staffIDs) {
            children.append(staff.encodeDeclaration(staffID: id, options: options))
        }
        // ...
        children.append(instrument.encode(options: options))
```

`MSCXEncoder+Staff.swift`:

```swift
extension Staff {
    func encodeDeclaration(
        staffID: String, options: MSCXEncoderOptions = .init()
    ) -> XMLTreeNode { /* body unchanged */ }

    func encodeTopLevel(
        staffID: String,
        titleFrame: ScoreFrame? = nil,
        options: MSCXEncoderOptions = .init()
    ) throws -> XMLTreeNode {
        // existing body, but call:
        // try measure.encode(carryInVoiceTieCarries: carry, options: options)
    }
}
```

`MSCXEncoder+Measure.swift`: add `options:` to both `encode()` and the carry-bearing `encode(carryInVoiceTieCarries:)`. Forward to `voice.encode(carryIn:options:)`.

`MSCXEncoder+Voice.swift`: add `options:` to `encode()` and `encode(carryIn:)` and the private `encode(element:…)`. Forward to chord/note/spanner/keySignature encode helpers.

`MSCXEncoder+Chord.swift`: add `options:` to `encodeAsChord` and `encodeAsRest`. Forward to `note.encode(tieForwardLocation:tieBackLocation:options:)`.

`MSCXEncoder+Note.swift`: add `options:` to `encode(tieForwardLocation:tieBackLocation:)`.

`MSCXEncoder+KeySignature.swift`: add `options:` to `encode()`.

`MSCXEncoder+Spanner.swift`: add `options:` to `encode()`. Forward to `nextLocationElement(options:)` / `payloadElement(options:)` (private helpers — keep them parameterised even if currently unused).

`MSCXEncoder+Instrument.swift`: add `options:` to `encode()`. Forward to `chan.encode(options:)`.

`MSCXEncoder+InstrumentChannel.swift`: add `options:` to `encode()`.

`MSCXEncoder+Score.swift`: in `Score.encode(options:)`, replace the inner calls so they pass `options`:

```swift
        scoreChildren.append(style.encode(options: options))
        // ...
        for (part, partID, ids) in allStaffIDs {
            scoreChildren.append(
                part.encodeDeclaration(partID: partID, staffIDs: ids, options: options))
        }
        // ...
        try scoreChildren.append(
            staff.encodeTopLevel(staffID: id, titleFrame: frame, options: options)
        )
```

- [ ] **Step 2: Build to confirm everything compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Run all tests**

Run: `swift test`
Expected: All existing tests still PASS (716+ + 4 from prior tasks). No behaviour change.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/
git commit -m "refactor(mscx): thread MSCXEncoderOptions through encoder helpers"
```

---

## Task 5: §A.1 — Root `<museScore version>` for v3

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

- [ ] **Step 1: Write the failing test**

Append to `MSCXEncoderMS3Tests.swift`:

```swift
@Test("v3 root museScore version is 3.02")
func v3RootVersionIs302() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    #expect(root.attributes["version"] == "3.02")
}

@Test("v4 root museScore version is 4.60")
func v4RootVersionIs460() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    #expect(root.attributes["version"] == "4.60")
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3RootVersionIs302`
Expected: FAIL with `version == "4.60"` for the v3 test.

- [ ] **Step 3: Branch on `options.targetVersion`**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`, replace the trailing `XMLTreeNode(name: "museScore", attributes: …)` literal with:

```swift
        let museScoreVersion: String
        switch options.targetVersion {
        case .v3: museScoreVersion = "3.02"
        case .v4: museScoreVersion = "4.60"
        }
        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": museScoreVersion],
            children: [
                XMLTreeNode(name: "Score", children: scoreChildren),
            ]
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit museScore version 3.02 for v3 target"
```

---

## Task 6: §A.2 — `<programVersion>` and `<programRevision>` for v3

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

These two children sit directly under `<museScore>`, **before** `<Score>`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 emits programVersion and programRevision before Score")
func v3EmitsProgramVersionAndRevision() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let names = root.children.map(\.name)
    #expect(names == ["programVersion", "programRevision", "Score"])
    #expect(root.first("programVersion")?.text == "3.6.2")
    #expect(root.first("programRevision")?.text == "3224f34")
}

@Test("v4 does not emit programVersion or programRevision")
func v4OmitsProgramVersionAndRevision() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let names = root.children.map(\.name)
    #expect(names == ["Score"])
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3EmitsProgramVersionAndRevision`
Expected: FAIL.

- [ ] **Step 3: Emit the two children for v3**

In `MSCXEncoder+Score.swift`, replace the final `return XMLTreeNode(name: "museScore", …)` block with:

```swift
        var rootChildren: [XMLTreeNode] = []
        if options.targetVersion == .v3 {
            rootChildren.append(XMLTreeNode(
                name: "programVersion", text: "3.6.2"
            ))
            rootChildren.append(XMLTreeNode(
                name: "programRevision", text: "3224f34"
            ))
        }
        rootChildren.append(XMLTreeNode(name: "Score", children: scoreChildren))
        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": museScoreVersion],
            children: rootChildren
        )
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit programVersion and programRevision for v3 target"
```

---

## Task 7: §A.3 — `<LayerTag>` and `<currentLayer>` for v3

These go inside `<Score>` **before** `<Division>`.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 emits LayerTag and currentLayer before Division")
func v3EmitsLayerTagBeforeDivision() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let scoreElement = try #require(root.first("Score"))
    let firstThree = scoreElement.children.prefix(3).map(\.name)
    #expect(firstThree == ["LayerTag", "currentLayer", "Division"])
    let layerTag = try #require(scoreElement.first("LayerTag"))
    #expect(layerTag.attributes["id"] == "0")
    #expect(layerTag.attributes["tag"] == "default")
    #expect(scoreElement.first("currentLayer")?.text == "0")
}

@Test("v4 has no LayerTag or currentLayer")
func v4OmitsLayerTag() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let scoreElement = try #require(root.first("Score"))
    #expect(scoreElement.first("LayerTag") == nil)
    #expect(scoreElement.first("currentLayer") == nil)
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3EmitsLayerTagBeforeDivision`
Expected: FAIL.

- [ ] **Step 3: Prepend the two children for v3**

In `MSCXEncoder+Score.swift`, change the start of `Score.encode(options:)` so `scoreChildren` begins with the LayerTag pair when targeting v3:

```swift
        var scoreChildren: [XMLTreeNode] = []
        if options.targetVersion == .v3 {
            scoreChildren.append(XMLTreeNode(
                name: "LayerTag",
                attributes: ["id": "0", "tag": "default"]
            ))
            scoreChildren.append(XMLTreeNode(
                name: "currentLayer", text: "0"
            ))
        }
        scoreChildren.append(XMLTreeNode(
            name: "Division", text: String(division)
        ))
        // …rest of body unchanged
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit LayerTag and currentLayer for v3 target"
```

---

## Task 8: §A.4 — `<showInvisible>` … `<showMargins>` for v3

These four flags go **after** `<Style>` and **before** the metaTags.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 emits show* flags after Style")
func v3EmitsShowFlagsAfterStyle() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let scoreElement = try #require(root.first("Score"))
    let names = scoreElement.children.map(\.name)
    let styleIndex = try #require(names.firstIndex(of: "Style"))
    #expect(Array(names[(styleIndex + 1)...(styleIndex + 4)])
        == ["showInvisible", "showUnprintable", "showFrames", "showMargins"])
    #expect(scoreElement.first("showInvisible")?.text == "1")
    #expect(scoreElement.first("showUnprintable")?.text == "1")
    #expect(scoreElement.first("showFrames")?.text == "1")
    #expect(scoreElement.first("showMargins")?.text == "0")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3EmitsShowFlagsAfterStyle`
Expected: FAIL.

- [ ] **Step 3: Insert the four flags after Style**

In `MSCXEncoder+Score.swift`, replace `scoreChildren.append(style.encode(options: options))` with:

```swift
        scoreChildren.append(style.encode(options: options))
        if options.targetVersion == .v3 {
            scoreChildren.append(XMLTreeNode(name: "showInvisible", text: "1"))
            scoreChildren.append(XMLTreeNode(name: "showUnprintable", text: "1"))
            scoreChildren.append(XMLTreeNode(name: "showFrames", text: "1"))
            scoreChildren.append(XMLTreeNode(name: "showMargins", text: "0"))
        }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit show* flags for v3 target"
```

---

## Task 9: §A.5 — Canonical 13 metaTags for v3

For v3 only: emit the fixed 13-element metaTag set in the documented order, with empty text when absent. `creationDate` defaults to today's date `yyyy-MM-dd` (UTC); `platform` defaults to `"Apple Macintosh"`. The other 11 default to empty string.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 emits canonical 13 metaTags in fixed order")
func v3EmitsCanonical13MetaTags() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let scoreElement = try #require(root.first("Score"))
    let metaNames = scoreElement.children
        .filter { $0.name == "metaTag" }
        .compactMap { $0.attributes["name"] }
    #expect(metaNames == [
        "arranger", "composer", "copyright", "creationDate",
        "lyricist", "movementNumber", "movementTitle", "platform",
        "poet", "source", "translator", "workNumber", "workTitle",
    ])
    let platform = scoreElement.children
        .first { $0.name == "metaTag" && $0.attributes["name"] == "platform" }
    #expect(platform?.text == "Apple Macintosh")
    let creationDate = scoreElement.children
        .first { $0.name == "metaTag" && $0.attributes["name"] == "creationDate" }
    let date = try #require(creationDate?.text)
    let regex = try Regex(#"^\d{4}-\d{2}-\d{2}$"#)
    #expect(date.wholeMatch(of: regex) != nil)
}

@Test("v3 metaTags use score-supplied values when present")
func v3MetaTagsUseScoreValues() throws {
    var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    score.metaTags["composer"] = "J. S. Bach"
    score.metaTags["platform"] = "Linux"
    score.metaTags["creationDate"] = "1750-07-28"
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let scoreElement = try #require(root.first("Score"))
    func value(_ name: String) -> String? {
        scoreElement.children
            .first { $0.name == "metaTag" && $0.attributes["name"] == name }?
            .text
    }
    #expect(value("composer") == "J. S. Bach")
    #expect(value("platform") == "Linux")
    #expect(value("creationDate") == "1750-07-28")
}

@Test("v4 metaTags use existing sorted-by-key emission")
func v4MetaTagsUnchanged() throws {
    var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    score.metaTags = ["composer": "X", "arranger": "Y"]
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let scoreElement = try #require(root.first("Score"))
    let metaNames = scoreElement.children
        .filter { $0.name == "metaTag" }
        .compactMap { $0.attributes["name"] }
    #expect(metaNames == ["arranger", "composer"])
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: FAIL on the three new tests (current code emits sorted score-supplied keys only).

- [ ] **Step 3: Branch metaTag emission**

In `MSCXEncoder+Score.swift`, replace the existing metaTags loop:

```swift
        for key in metaTags.keys.sorted() {
            scoreChildren.append(XMLTreeNode(
                name: "metaTag",
                attributes: ["name": key],
                text: metaTags[key] ?? ""
            ))
        }
```

with:

```swift
        scoreChildren.append(contentsOf: encodedMetaTags(options: options))
```

Then add a private helper inside the same file (outside the extension), and wire it through:

```swift
private extension Score {
    func encodedMetaTags(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        switch options.targetVersion {
        case .v4:
            return metaTags.keys.sorted().map { key in
                XMLTreeNode(
                    name: "metaTag",
                    attributes: ["name": key],
                    text: metaTags[key] ?? ""
                )
            }
        case .v3:
            return Self.canonicalMS3MetaTagNames.map { name in
                XMLTreeNode(
                    name: "metaTag",
                    attributes: ["name": name],
                    text: ms3MetaValue(for: name)
                )
            }
        }
    }

    func ms3MetaValue(for name: String) -> String {
        if let supplied = metaTags[name], !supplied.isEmpty { return supplied }
        switch name {
        case "creationDate": return Self.todayISODate
        case "platform": return "Apple Macintosh"
        default: return ""
        }
    }

    static let canonicalMS3MetaTagNames: [String] = [
        "arranger", "composer", "copyright", "creationDate",
        "lyricist", "movementNumber", "movementTitle", "platform",
        "poet", "source", "translator", "workNumber", "workTitle",
    ]

    static var todayISODate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: All Task 1–9 tests PASS.

Run: `swift test`
Expected: 716+ existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit canonical 13-element metaTags for v3 target"
```

---

## Task 10: §B — `<Style>` is `<Spatium>` only for v3

v3 emits one `<Spatium>` (capital S) child holding `String(spatium)`. All other Phase 2.5 / 3 fields are skipped unconditionally.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 Style block has only <Spatium> child (capital S)")
func v3StyleEmitsOnlyCapitalSpatium() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let style = try #require(root.first("Score")?.first("Style"))
    #expect(style.children.count == 1)
    #expect(style.children[0].name == "Spatium")
    #expect(style.children[0].text == String(score.style.spatium))
}

@Test("v4 Style block keeps existing emission (lowercase spatium)")
func v4StyleEmissionUnchanged() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let style = try #require(root.first("Score")?.first("Style"))
    #expect(style.first("spatium") != nil)
    #expect(style.first("Spatium") == nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3StyleEmitsOnlyCapitalSpatium`
Expected: FAIL.

- [ ] **Step 3: Branch the Style encoder**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`, replace the body of `ScoreStyle.encode(options:)` with:

```swift
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        switch options.targetVersion {
        case .v3:
            return XMLTreeNode(name: "Style", children: [
                XMLTreeNode(name: "Spatium", text: String(spatium)),
            ])
        case .v4:
            let defaults = ScoreStyle.museScoreDefaults
            var children: [XMLTreeNode] = []
            appendPageLayout(pageLayout, defaults: defaults.pageLayout, into: &children)
            children.append(double("spatium", spatium))
            appendHeader(
                pageChrome.header,
                defaults: defaults.pageChrome.header,
                into: &children
            )
            appendFooter(
                pageChrome.footer,
                defaults: defaults.pageChrome.footer,
                into: &children
            )
            appendPageNumber(
                pageChrome.pageNumber,
                defaults: defaults.pageChrome.pageNumber,
                into: &children
            )
            return XMLTreeNode(name: "Style", children: children)
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

Run: `swift test`
Expected: existing Style/RoundTrip tests still PASS (they all run via `.v4`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit Spatium-only Style block for v3 target"
```

---

## Task 11: §C.1 — Drop initial `KeySig` with key == 0 (both versions)

When the first VoiceElement of voice 0 in measure 0 of a staff is a `KeySignature` with `concertKey == 0`, omit it. Affects both v3 and v4.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`

The Voice encoder needs a flag "is this the first voice of the first measure of the staff" so it can drop the initial-zero KeySig. We pass this down via a new defaulted parameter `isStaffHeadVoice: Bool = false`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("Initial KeySig with concertKey 0 is omitted (v4)")
func initialZeroKeySigOmittedV4() throws {
    var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    // Force a leading C-major KeySig on staff 0 / measure 0 / voice 0
    var voice = score.parts[0].staves[0].measures[0].voices[0]
    let elements = voice.elements.first.map { _ in voice.elements } ?? []
    var newElements = [VoiceElement.keySignature(KeySignature(concertKey: 0))]
    newElements.append(contentsOf: elements.filter {
        if case .keySignature = $0 { return false } else { return true }
    })
    voice.elements = newElements
    score.parts[0].staves[0].measures[0].voices[0] = voice

    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let firstStaff = root.first("Score")?.children
        .filter { $0.name == "Staff" }
        .last  // top-level (body) Staff comes after declarations
    let firstMeasure = try #require(firstStaff?.first("Measure"))
    let firstVoice = try #require(firstMeasure.first("voice"))
    #expect(firstVoice.first("KeySig") == nil)
}

@Test("Mid-piece KeySig change still emitted (v4)")
func midKeySigChangeStillEmittedV4() throws {
    var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    // Insert a KeySig change on measure 1 / voice 0 if that measure exists.
    guard score.parts[0].staves[0].measures.count >= 2 else { return }
    var v = score.parts[0].staves[0].measures[1].voices[0]
    v.elements.insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
    score.parts[0].staves[0].measures[1].voices[0] = v
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let staffBody = root.first("Score")?.children
        .filter { $0.name == "Staff" }.last
    let secondMeasure = staffBody?.children.filter { $0.name == "Measure" }[1]
    #expect(secondMeasure?.first("voice")?.first("KeySig") != nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/initialZeroKeySigOmittedV4`
Expected: FAIL (KeySig is still emitted).

- [ ] **Step 3: Add an `isStaffHead` flag through Staff → Measure → Voice**

In `MSCXEncoder+Staff.swift`, change the `encodeTopLevel` measure loop:

```swift
        var carry: [Voice.VoiceTieCarry] = []
        for (measureIndex, measure) in measures.enumerated() {
            let result = try measure.encode(
                carryInVoiceTieCarries: carry,
                isFirstMeasureOfStaff: measureIndex == 0,
                options: options
            )
            children.append(result.node)
            carry = result.carryOutVoiceTieCarries
        }
```

In `MSCXEncoder+Measure.swift`, change `encode(carryInVoiceTieCarries:options:)` to also take `isFirstMeasureOfStaff: Bool = false`, and pass `isStaffHead: index == 0 && isFirstMeasureOfStaff` to `voice.encode(carryIn:isStaffHead:options:)`.

In `MSCXEncoder+Voice.swift`, add `isStaffHead: Bool = false` to `encode(carryIn:options:)` and the private helper. In the loop body, before processing element 0, drop it from emission when:

```swift
    let dropInitialZeroKeySig: Bool = {
        guard isStaffHead, let first = elements.first else { return false }
        if case let .keySignature(key) = first, key.concertKey == 0 { return true }
        return false
    }()
    // …
    for (index, element) in elements.enumerated() {
        // …
        if dropInitialZeroKeySig && index == 0 {
            // skip emission, but still walk tuplet open/close bookkeeping for safety
            continue
        }
        // …existing per-element handling
    }
```

(Tuplet bookkeeping doesn't apply to a `.keySignature` element since key signatures aren't tuplet members; the `continue` is safe.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

Run: `swift test`
Expected: existing tests still PASS — round-trip fixtures don't rely on a leading KeySig 0 being emitted because most don't carry one in voice 0 of measure 0 (the parser emits KeySig only when the file declares one). Investigate any failure rather than weakening the rule.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift \
        Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): drop initial concertKey-0 KeySig from staff head"
```

---

## Task 12: §C.2 — v3 KeySig body uses `<accidental>` instead of `<concertKey>`

Spec test 5 documents the v3 wire-form body: `<KeySig><accidental>N</accidental></KeySig>`. v4 keeps the existing `<concertKey>` body.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 mid-piece KeySig change emits <accidental>")
func v3MidKeySigEmitsAccidental() throws {
    var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    guard score.parts[0].staves[0].measures.count >= 2 else { return }
    var v = score.parts[0].staves[0].measures[1].voices[0]
    v.elements.insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
    score.parts[0].staves[0].measures[1].voices[0] = v
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)
    let staffBody = root.first("Score")?.children
        .filter { $0.name == "Staff" }.last
    let secondMeasure = staffBody?.children.filter { $0.name == "Measure" }[1]
    let keySig = try #require(secondMeasure?.first("voice")?.first("KeySig"))
    #expect(keySig.first("accidental")?.text == "2")
    #expect(keySig.first("concertKey") == nil)
}

@Test("v4 KeySig body keeps <concertKey>")
func v4KeySigKeepsConcertKey() throws {
    var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    guard score.parts[0].staves[0].measures.count >= 2 else { return }
    var v = score.parts[0].staves[0].measures[1].voices[0]
    v.elements.insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
    score.parts[0].staves[0].measures[1].voices[0] = v
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
    let root = try XMLTreeParser.parse(bytes)
    let staffBody = root.first("Score")?.children
        .filter { $0.name == "Staff" }.last
    let secondMeasure = staffBody?.children.filter { $0.name == "Measure" }[1]
    let keySig = try #require(secondMeasure?.first("voice")?.first("KeySig"))
    #expect(keySig.first("concertKey")?.text == "2")
    #expect(keySig.first("accidental") == nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3MidKeySigEmitsAccidental`
Expected: FAIL.

- [ ] **Step 3: Branch on `options.targetVersion`**

Replace `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension KeySignature {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        let childName: String
        switch options.targetVersion {
        case .v3: childName = "accidental"
        case .v4: childName = "concertKey"
        }
        return XMLTreeNode(
            name: "KeySig",
            children: [
                XMLTreeNode(name: childName, text: String(concertKey)),
            ]
        )
    }
}
```

Update the call site in `MSCXEncoder+Voice.swift` so the keySignature case forwards options:

```swift
        case let .keySignature(key):
            return key.encode(options: options)
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

Run: `swift test`
Expected: existing tests still PASS (they all use the v4 default).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift \
        Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit <accidental> body in KeySig for v3 target"
```

---

## Task 13: §E — Spanner `<location>` order reversal for v3

Inside `<next><location>`: v3 emits `<measures>` then `<fractions>`; v4 keeps existing `<fractions>` then `<measures>`. "Skip if default" semantics stay the same.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 Spanner location emits <measures> before <fractions>")
func v3SpannerLocationOrderReversed() throws {
    let spanner = Spanner(
        kind: .hairpin,
        rawType: "HairPin",
        nextMeasuresOffset: 1,
        nextFractionsOffset: Fraction(numerator: 1, denominator: 4)
    )
    let xml = spanner.encode(options: .init(targetVersion: .v3))
    let location = try #require(xml.first("next")?.first("location"))
    #expect(location.children.map(\.name) == ["measures", "fractions"])
}

@Test("v4 Spanner location order unchanged (fractions first)")
func v4SpannerLocationOrderUnchanged() throws {
    let spanner = Spanner(
        kind: .hairpin,
        rawType: "HairPin",
        nextMeasuresOffset: 1,
        nextFractionsOffset: Fraction(numerator: 1, denominator: 4)
    )
    let xml = spanner.encode(options: .init(targetVersion: .v4))
    let location = try #require(xml.first("next")?.first("location"))
    #expect(location.children.map(\.name) == ["fractions", "measures"])
}

@Test("v3 Spanner skip-if-default still applies")
func v3SpannerSkipIfDefault() throws {
    let spanner = Spanner(
        kind: .hairpin,
        rawType: "HairPin",
        nextMeasuresOffset: 0,
        nextFractionsOffset: nil
    )
    let xml = spanner.encode(options: .init(targetVersion: .v3))
    #expect(xml.first("next") == nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3SpannerLocationOrderReversed`
Expected: FAIL.

- [ ] **Step 3: Branch the location-children order**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`, replace `nextLocationElement()` with:

```swift
    private func nextLocationElement(options: MSCXEncoderOptions) -> XMLTreeNode? {
        let fractionsNode: XMLTreeNode? = nextFractionsOffset.map {
            XMLTreeNode(
                name: "fractions",
                text: "\($0.numerator)/\($0.denominator)"
            )
        }
        let measuresNode: XMLTreeNode? = nextMeasuresOffset != 0
            ? XMLTreeNode(name: "measures", text: String(nextMeasuresOffset))
            : nil
        var locationChildren: [XMLTreeNode] = []
        switch options.targetVersion {
        case .v3:
            if let measuresNode { locationChildren.append(measuresNode) }
            if let fractionsNode { locationChildren.append(fractionsNode) }
        case .v4:
            if let fractionsNode { locationChildren.append(fractionsNode) }
            if let measuresNode { locationChildren.append(measuresNode) }
        }
        guard !locationChildren.isEmpty else { return nil }
        return XMLTreeNode(name: "next", children: [
            XMLTreeNode(name: "location", children: locationChildren),
        ])
    }
```

Then in the public `encode(options:)`, change the call to `if let next = nextLocationElement(options: options) { … }`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

Run: `swift test --filter MSCXEncoderSpannerFractionsTests`
Expected: PASS (those tests use the v4 default).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): reverse Spanner <location> order for v3 target"
```

---

## Task 14: §F — Channel default suppression + Bank LSB for v3

For v3 only:
- Drop `<midiPort>` when `midiPort == 0` or `nil`.
- Drop `<midiChannel>` when `midiChannel == 0` or `nil`.
- After emitting `<controller ctrl="0" value="X"/>` (Bank MSB) — which Phase 1 emits via `bank` — also emit `<controller ctrl="32" value="0"/>` (Bank LSB).

Note on Bank MSB: the existing encoder emits `bank` on `ctrl="32"` (Bank LSB) per current Phase 1 code. **Re-read** `MSCXEncoder+InstrumentChannel.swift:39` before writing the v3 branch — it currently uses ctrl 32 for `bank`. The §F description in the spec says "Bank MSB" + Bank LSB; the actual canonical evidence may map either way. If the existing emission already uses ctrl 32 for `bank`, the v3 branch instead emits ctrl 0 (Bank MSB) for `bank` plus ctrl 32 (Bank LSB) = 0. Verify against `~/Desktop/test-min.mscx` content as captured in the spec; if uncertain, ask the user before committing this task.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 default Channel omits <midiPort> and <midiChannel>")
func v3ChannelOmitsDefaults() throws {
    let chan = InstrumentChannel(midiChannel: nil, midiPort: nil)
    let xml = chan.encode(options: .init(targetVersion: .v3))
    #expect(xml.first("midiPort") == nil)
    #expect(xml.first("midiChannel") == nil)
}

@Test("v3 zero Channel still omits <midiPort> and <midiChannel>")
func v3ChannelOmitsZeroDefaults() throws {
    let chan = InstrumentChannel(midiChannel: 0, midiPort: 0)
    let xml = chan.encode(options: .init(targetVersion: .v3))
    #expect(xml.first("midiPort") == nil)
    #expect(xml.first("midiChannel") == nil)
}

@Test("v4 Channel keeps existing <midiPort> / <midiChannel> emission")
func v4ChannelKeepsDefaults() throws {
    let chan = InstrumentChannel(midiChannel: 0, midiPort: 0)
    let xml = chan.encode(options: .init(targetVersion: .v4))
    #expect(xml.first("midiPort")?.text == "0")
    #expect(xml.first("midiChannel")?.text == "0")
}

@Test("v3 emits Bank LSB controller after Bank MSB")
func v3ChannelEmitsBankLSB() throws {
    let chan = InstrumentChannel(bank: 1)  // any non-default to trigger bank emission
    let xml = chan.encode(options: .init(targetVersion: .v3))
    let controllers = xml.children
        .filter { $0.name == "controller" }
    let ctrls = controllers.compactMap { $0.attributes["ctrl"] }
    #expect(ctrls.contains("32"))
    // v3 always emits the LSB pair, even when LSB value is 0
    let lsb = controllers.first { $0.attributes["ctrl"] == "32" }
    #expect(lsb?.attributes["value"] == "0")
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3ChannelOmitsDefaults`
Expected: FAIL.

- [ ] **Step 3: Branch `InstrumentChannel.encode`**

Replace `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift` body so the midiPort/midiChannel emission and the bank-LSB pair both gate on `options.targetVersion`. Concrete edits inside `encode(options:)`:

```swift
        if let midiChannel, !(options.targetVersion == .v3 && midiChannel == 0) {
            children.append(XMLTreeNode(
                name: "midiChannel", text: String(midiChannel)
            ))
        }
        if let midiPort, !(options.targetVersion == .v3 && midiPort == 0) {
            children.append(XMLTreeNode(
                name: "midiPort", text: String(midiPort)
            ))
        }
```

For the bank LSB pair, after the existing `if bank != defaults.bank { children.append(controllerNode(ctrl: 32, value: bank)) }` block:

```swift
        if options.targetVersion == .v3, bank != defaults.bank {
            // MS3 canonical writes both bank-select bytes; ctrl 32 (LSB)
            // pairs with ctrl 0 (MSB) per GM-2 convention.
            children.append(controllerNode(ctrl: 0, value: bank))
            // The existing ctrl 32 emission above is the LSB; we add
            // the MSB. If MS3 canonical emits a literal ctrl 32 = 0
            // pair *in addition*, append it here. Verify against
            // ~/Desktop/test-min.mscx before finalising.
        }
```

> **Implementation note:** The exact controller pair MS3 canonically emits depends on the on-disk reference. If the spec author's intent (per §F) is "Bank MSB on ctrl 0 and Bank LSB on ctrl 32, both always present for v3", adjust the v3 branch so both controllers are emitted unconditionally when targeting v3. Confirm with the user using the canonical `~/Desktop/test-min.mscx` before committing this task.

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

Run: `swift test`
Expected: existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): drop default midiPort/midiChannel and emit Bank LSB for v3"
```

---

## Task 15: §G — Drum chord stem direction + note head for v3

When the chord lives on a percussion staff (`StaffType.group == "percussion"`) AND `options.targetVersion == .v3`:
- Chord emits `<StemDirection>up</StemDirection>` for voice index 0, `<StemDirection>down</StemDirection>` for voice index 1+, as the first child of `<Chord>`, before `<durationType>`.
- Note emits `<head>` matching the score's drumset definition for that pitch (fall back to `"normal"` when missing).

The Chord and Note encoders need three new pieces of context:
- `staffGroup: String` (so they know whether the chord is on percussion)
- `voiceIndex: Int` (so they can pick stem direction)
- `drumLineMap` and any drumset metadata available — the `headType` already lives on `Note`, so reuse it when set; otherwise default to `"normal"`.

The cleanest plumbing is to thread `staffGroup` and `voiceIndex` through `Voice.encode` (which already iterates voices in a measure and has the staff context one frame up).

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("v3 percussion chord emits StemDirection and head")
func v3DrumChordEmitsStemDirectionAndHead() throws {
    let drumNote = Note(pitch: 38, tpc: 14, headType: "slash")
    let chord = Chord(
        duration: .quarter,
        notes: [drumNote]
    )
    let xml = chord.encodeAsChord(
        options: .init(targetVersion: .v3),
        staffGroup: "percussion",
        voiceIndex: 0
    )
    let firstChild = try #require(xml.children.first)
    #expect(firstChild.name == "StemDirection")
    #expect(firstChild.text == "up")
    let note = try #require(xml.first("Note"))
    #expect(note.first("head")?.text == "slash")
}

@Test("v3 percussion chord on voice 1 emits StemDirection down")
func v3DrumChordVoice1StemDown() throws {
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 36, tpc: 14)]
    )
    let xml = chord.encodeAsChord(
        options: .init(targetVersion: .v3),
        staffGroup: "percussion",
        voiceIndex: 1
    )
    let firstChild = try #require(xml.children.first)
    #expect(firstChild.name == "StemDirection")
    #expect(firstChild.text == "down")
}

@Test("v3 percussion note without headType defaults to normal")
func v3DrumNoteHeadDefaultsToNormal() throws {
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 36, tpc: 14)]  // no headType
    )
    let xml = chord.encodeAsChord(
        options: .init(targetVersion: .v3),
        staffGroup: "percussion",
        voiceIndex: 1
    )
    let note = try #require(xml.first("Note"))
    #expect(note.first("head")?.text == "normal")
}

@Test("v4 percussion chord emits no StemDirection")
func v4DrumChordOmitsStemDirection() throws {
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 38, tpc: 14)]
    )
    let xml = chord.encodeAsChord(
        options: .init(targetVersion: .v4),
        staffGroup: "percussion",
        voiceIndex: 0
    )
    #expect(xml.first("StemDirection") == nil)
}

@Test("v3 pitched-staff chord emits no StemDirection")
func v3PitchedStaffChordOmitsStemDirection() throws {
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 60, tpc: 14)]
    )
    let xml = chord.encodeAsChord(
        options: .init(targetVersion: .v3),
        staffGroup: "pitched",
        voiceIndex: 0
    )
    #expect(xml.first("StemDirection") == nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MSCXEncoderMS3Tests/v3DrumChordEmitsStemDirectionAndHead`
Expected: FAIL with "incorrect argument labels".

- [ ] **Step 3: Add `staffGroup` and `voiceIndex` parameters**

In `MSCXEncoder+Chord.swift`, replace the body of `encodeAsChord(...)`:

```swift
    func encodeAsChord(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        let isPercussionV3 =
            options.targetVersion == .v3 && staffGroup == "percussion"
        if isPercussionV3 {
            children.append(XMLTreeNode(
                name: "StemDirection",
                text: voiceIndex == 0 ? "up" : "down"
            ))
        }
        duration.appendDurationXML(to: &children)
        for note in notes {
            children.append(note.encode(
                tieForwardLocation: tieForwardLocation,
                tieBackLocation: tieBackLocation,
                options: options,
                drumDefaultHead: isPercussionV3 ? "normal" : nil
            ))
        }
        return XMLTreeNode(name: "Chord", children: children)
    }
```

In `MSCXEncoder+Note.swift`, change the encode signature to:

```swift
    func encode(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        options: MSCXEncoderOptions = .init(),
        drumDefaultHead: String? = nil
    ) -> XMLTreeNode {
        // existing body, except change the head emission:
        if let headType {
            children.append(XMLTreeNode(name: "head", text: headType))
        } else if let drumDefaultHead {
            children.append(XMLTreeNode(name: "head", text: drumDefaultHead))
        }
        // …
    }
```

In `MSCXEncoder+Voice.swift`, propagate `staffGroup` and `voiceIndex` to the chord case in the per-element switch:

```swift
    func encode(
        carryIn: VoiceTieCarry,
        isStaffHead: Bool = false,
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
        options: MSCXEncoderOptions = .init()
    ) throws -> (node: XMLTreeNode, carryOut: VoiceTieCarry) { … }

    // inside private encode(element:…):
    case let .chord(chord):
        // existing tie/tuplet logic …
        return unscaledChord.notes.isEmpty
            ? unscaledChord.encodeAsRest(options: options)
            : unscaledChord.encodeAsChord(
                tieForwardLocation: tieForward,
                tieBackLocation: tieBack,
                options: options,
                staffGroup: staffGroup,
                voiceIndex: voiceIndex
            )
```

In `MSCXEncoder+Measure.swift`, change `encode(carryInVoiceTieCarries:isFirstMeasureOfStaff:options:)` to also take `staffGroup: String = "pitched"`, and pass `voiceIndex: index` and `staffGroup: staffGroup` into `voice.encode(...)`.

In `MSCXEncoder+Staff.swift`, the `encodeTopLevel` body now passes `staffGroup: self.group` to each `measure.encode(...)`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter MSCXEncoderMS3Tests`
Expected: PASS.

Run: `swift test`
Expected: existing tests still PASS (the new params all default to pitched / voice 0 / v4).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift \
        Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "feat(mscx): emit StemDirection and drum head for percussion v3 chord"
```

---

## Task 16: Existing-MS4-path regression test

Spec test 9. Belt-and-suspenders: confirms passing `.init()` explicitly through the new API matches the legacy zero-arg call.

**Files:**
- Modify: `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift` (test already added in Task 3 — keep it)

- [ ] **Step 1: Verify the existing `encodeOptionsV4DefaultMatchesLegacy` test still passes**

Run: `swift test --filter MSCXEncoderMS3Tests/encodeOptionsV4DefaultMatchesLegacy`
Expected: PASS.

- [ ] **Step 2: Run the full suite to confirm no regression**

Run: `swift test`
Expected: All tests PASS (716+ legacy + new MS3 tests).

- [ ] **Step 3: No commit needed (no source change)**

---

## Task 17: midi01 canonical-fields parity test

Spec test 10. Encode the parsed midi01 score with `.v3`, reparse, assert root attributes and Style children match the canonical MS3 form documented in §A and §B. Avoids importing the desktop file as a fixture.

**Files:**
- Modify: `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift`

- [ ] **Step 1: Write the test**

Append:

```swift
@Test("midi01 v3 round-trip matches canonical MS3 root + Style fields")
func midi01CanonicalKeyFieldsMatch() throws {
    let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
    let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
    let root = try XMLTreeParser.parse(bytes)

    // Root: §A
    #expect(root.attributes["version"] == "3.02")
    #expect(root.first("programVersion")?.text == "3.6.2")
    #expect(root.first("programRevision")?.text == "3224f34")
    let scoreElement = try #require(root.first("Score"))
    let firstNames = scoreElement.children.prefix(3).map(\.name)
    #expect(firstNames == ["LayerTag", "currentLayer", "Division"])
    let postStyle = scoreElement.children
        .drop(while: { $0.name != "Style" })
        .dropFirst()
        .prefix(4)
        .map(\.name)
    #expect(postStyle == ["showInvisible", "showUnprintable", "showFrames", "showMargins"])

    // Style: §B
    let style = try #require(scoreElement.first("Style"))
    #expect(style.children.count == 1)
    #expect(style.children[0].name == "Spatium")
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter MSCXEncoderMS3Tests/midi01CanonicalKeyFieldsMatch`
Expected: PASS (all underlying behaviours land in Tasks 5–10).

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift
git commit -m "test(mscx): assert midi01 v3 export matches canonical MS3 root + Style"
```

---

## Task 18: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read README to find the right insertion spot**

Read `README.md` and locate the section that mentions `exportMSCX` / `exportMSCZ` (probably the "Export" or "API" subsection).

- [ ] **Step 2: Add a one-line note**

Add (or extend) a sentence beneath the existing export reference:

```markdown
`MSCXEncoderOptions(targetVersion: .v3)` produces MuseScore-3.6.2-flavoured `.mscx` / `.mscz`; `.v4` (default) keeps the current MuseScore-4 wire form.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): mention MSCXEncoderOptions targetVersion"
```

---

## Task 19: Lint + full test sweep

**Files:** none (verification only).

- [ ] **Step 1: Run SwiftLint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings, 0 errors.

If anything fires, fix the offending file (most likely `MSCXEncoder+Score.swift` or `MSCXEncoder+Voice.swift` for line-length / function-length after the v3 branches). Splitting `MSCXEncoder+Score.swift` into `…+Score.swift` (top-level entry) plus `…+Score+MS3Header.swift` (program/version/Layer/show flags/metaTags) is a reasonable cure if file length exceeds 300.

- [ ] **Step 2: Run the full test suite**

Run: `swift test`
Expected: ALL tests PASS — 716+ legacy plus ~22 MS3 tests added across Tasks 1–17.

- [ ] **Step 3: Commit any lint fixes**

```bash
git add Sources/SheetMusicMSCX/Encoders/
git commit -m "style(mscx): split MSCXEncoder+Score for SwiftLint file-length"
```

(skip if no fix needed)

---

## Task 20: Manual acceptance on MuseScore 3.6.2

**Files:** none (manual verification).

- [ ] **Step 1: Pick a small MIDI file**

Use any small `.mid` not in `Tests/SheetMusicTests/Resources/`. (You can write a small ad-hoc Swift script that takes a `.mid` path and writes a `.mscz` next to it.)

- [ ] **Step 2: Round-trip via the new API**

```swift
import SheetMusic
let score = try SheetMusic.loadScore(midiURL: midiURL)
let outURL = midiURL.deletingPathExtension().appendingPathExtension("mscz")
try SheetMusic.exportMSCZ(score, options: .init(targetVersion: .v3), to: outURL)
print("wrote \(outURL.path)")
```

(Either drive this from a quick `swift run` snippet under `Examples/`, or call from a one-off scratch test that writes to `/tmp` and prints the path.)

- [ ] **Step 3: Open in MuseScore 3.6.2 and verify**

Hand the file to the user. They confirm visible structure: number of staves correct, KeySig and TimeSig as expected, Tuplet renders with bracket and number, Tie connects across measures, drumset stems differ between voices (when present).

- [ ] **Step 4: If anything fails, debug**

Diff the encoder output against `~/Desktop/test-min.mscx` field-by-field. The canonical reference is the ground truth; patch the v3 branch in the relevant `MSCXEncoder+*.swift`.

- [ ] **Step 5: No commit unless a fix lands**

If a fix is needed, repeat the relevant prior task (15 → adjust → commit) before declaring done.

---

## Self-review

**Spec coverage:**
- §A.1 root version → Task 5 ✓
- §A.2 programVersion + programRevision → Task 6 ✓
- §A.3 LayerTag + currentLayer → Task 7 ✓
- §A.4 show* flags → Task 8 ✓
- §A.5 canonical 13 metaTags → Task 9 ✓
- §B Style Spatium-only → Task 10 ✓
- §C.1 drop initial KeySig 0 → Task 11 ✓
- §C.2 v3 KeySig body uses `<accidental>` → Task 12 ✓
- §D TimeSig — no change needed (spec confirms; no task) ✓
- §E Spanner location order → Task 13 ✓
- §F Channel default suppression + Bank LSB → Task 14 ✓
- §G Drum stem + head → Task 15 ✓
- §H Untouched — by construction ✓
- Architecture: MSCXVersion + MSCXEncoderOptions + façade overloads → Tasks 1–3 ✓
- Internal plumbing → Task 4 ✓
- 10 spec tests → covered: rootHeader (5,6,7,8), metaTags (9), styleSpatium (10), initialKeySigZeroOmitted (11), midKeySigChangeEmitted (12), spannerLocationOrderV3 (13), channelOmits (14), drumChord (15), existingMS4Path (16), midi01CanonicalFields (17) ✓
- README → Task 18 ✓
- Manual acceptance → Task 20 ✓

**Open question (flagged in Task 14):** The exact Bank MSB/LSB controller-pair for v3 depends on what `~/Desktop/test-min.mscx` actually emits. The plan describes both interpretations and asks the implementer to confirm with the user before committing Task 14.

**Open question (Task 12):** Spec §C says "Mid-piece KeySig changes … emit unchanged in both versions." Spec test 5 (`midKeySigChangeEmitted`) asserts `<accidental>2</accidental>`, which contradicts the prose if v4 also emits `<concertKey>`. The plan resolves it by treating test 5 as describing the v3 wire form (matching MS3 canonical) and adding a v3-only branch in `MSCXEncoder+KeySignature.swift`. If the spec author intends both versions to switch to `<accidental>`, drop the v4 branch in Task 12.

**Type / signature consistency:** The `options: MSCXEncoderOptions = .init()` defaulted parameter is added to every encode helper in Task 4 before any v3 branch references it. `staffGroup: String` and `voiceIndex: Int` are introduced in Task 15 only at the call sites that need them (Chord, Note, Voice, Measure, Staff). `isStaffHead: Bool` is introduced in Task 11 at Voice and threaded one frame from Measure. No method renames between tasks.
