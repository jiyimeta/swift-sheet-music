# Anacrusis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Measure.actualLength` and `Measure.irregular` fields, round-trip them through MSCX, and skip irregular measures in layout-emitted measure numbers.

**Architecture:** Pure additive change. Two new fields on `Measure` (defaulted), MSCX decode/encode read/write the corresponding XML, and a new `Score.displayedMeasureNumber(at:)` helper feeds both layout call-sites that emit `.measureNumber`. MIDI rendering is intentionally untouched — `MidiRenderer.measureTicks` already derives ticks from voice contents, which match the new `actualLength` for well-formed files.

**Tech Stack:** Swift Package Manager · Swift Testing (`@Test` / `#expect`) · Foundation `XMLParser`-backed `XMLTreeParser` for MSCX I/O.

**Reference:** `docs/superpowers/specs/2026-05-08-anacrusis-design.md`.

---

## File Structure

**Create:**
- `Sources/SheetMusicCore/Score/Score+MeasureNumber.swift` — `Score.displayedMeasureNumber(at:)` helper, sole responsibility: irregular-skipping numbering.
- `Tests/SheetMusicTests/AnacrusisTests.swift` — single suite covering Core helper, MSCX decode, MSCX round-trip, and Layout numbering.

**Modify:**
- `Sources/SheetMusicCore/Score/Measure.swift` — add `actualLength` and `irregular` stored properties + initializer parameters.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Measure.swift` — read `len` attribute + `<irregular>` element.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift` — emit `len` attribute on the `<Measure>` node; emit `<irregular>1</irregular>` after markers/`<startRepeat/>` and before voices.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift` — `LayoutMeasureContext` gains `displayedMeasureNumber: Int?`; the builder fills it; `stickyHeaderSystem` consults it instead of `measureIndex + 1`, suppressing the marker when `nil`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift` — per-system head label uses `context.score.displayedMeasureNumber(at: measureIdx)`, suppressing emission on `nil`.

---

## Task 1: Add `Measure.actualLength` and `Measure.irregular`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Measure.swift`
- Test: `Tests/SheetMusicTests/AnacrusisTests.swift` (new file, first test added in this task)

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AnacrusisTests.swift`:

```swift
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct AnacrusisTests {
    @Test func measureCarriesActualLengthAndIrregular() {
        let pickup = Measure(
            voices: [],
            actualLength: Fraction(numerator: 1, denominator: 4),
            irregular: true
        )
        #expect(pickup.actualLength == Fraction(numerator: 1, denominator: 4))
        #expect(pickup.irregular == true)

        let normal = Measure(voices: [])
        #expect(normal.actualLength == nil)
        #expect(normal.irregular == false)

        // Equatable should pick up the new fields.
        #expect(pickup != Measure(voices: [], irregular: true))
        #expect(pickup != Measure(
            voices: [],
            actualLength: Fraction(numerator: 1, denominator: 4)
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnacrusisTests`
Expected: compile error — `Measure.init` has no `actualLength` / `irregular` parameters.

- [ ] **Step 3: Add the fields and initializer parameters**

Edit `Sources/SheetMusicCore/Score/Measure.swift` so the type reads:

```swift
import Foundation

/// A measure (bar) made up of one or more `Voice`s. C++: `mu::engraving::Measure`.
public struct Measure: Sendable, Equatable {
    public var voices: [Voice]
    public var startRepeat: Bool
    public var endRepeatCount: Int?
    public var measureRepeatCount: Int?
    public var markers: [Marker]
    public var jumps: [Jump]
    public var lineBreak: Bool
    public var pageBreak: Bool
    /// `<Measure len="N/D">` — actual measure length when it differs from
    /// the prevailing time signature. `nil` means "follow the time
    /// signature". Mirrors `Measure::ticks()` vs `nominalTicks()` in
    /// MuseScore.
    public var actualLength: Fraction?
    /// `<irregular>1</irregular>` — exclude this measure from the running
    /// displayed measure number. Typically set on an anacrusis.
    public var irregular: Bool

    public init(
        voices: [Voice],
        startRepeat: Bool = false,
        endRepeatCount: Int? = nil,
        measureRepeatCount: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
        lineBreak: Bool = false,
        pageBreak: Bool = false,
        actualLength: Fraction? = nil,
        irregular: Bool = false
    ) {
        self.voices = voices
        self.startRepeat = startRepeat
        self.endRepeatCount = endRepeatCount
        self.measureRepeatCount = measureRepeatCount
        self.markers = markers
        self.jumps = jumps
        self.lineBreak = lineBreak
        self.pageBreak = pageBreak
        self.actualLength = actualLength
        self.irregular = irregular
    }
}
```

Keep all existing doc comments on the prior properties verbatim — only the two new properties and two initializer parameters are added. (Doc-comment text on the existing fields is shown abbreviated above for readability; preserve the original lines.)

- [ ] **Step 4: Run the new test plus the full suite**

Run: `swift test --filter AnacrusisTests`
Expected: PASS.

Run: `swift test`
Expected: all 12 suites still green. Existing call-sites use the memberwise initializer with default-tail arguments, so no other compile errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Measure.swift \
        Tests/SheetMusicTests/AnacrusisTests.swift
git commit -m "feat(core): Measure.actualLength + Measure.irregular fields"
```

---

## Task 2: Add `Score.displayedMeasureNumber(at:)`

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+MeasureNumber.swift`
- Test: `Tests/SheetMusicTests/AnacrusisTests.swift` (append a test to the existing suite)

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AnacrusisTests.swift` inside the suite:

```swift
@Test func displayedMeasureNumberSkipsIrregular() {
    let staff = Staff(measures: [
        Measure(voices: [Voice(elements: [])], irregular: true),
        Measure(voices: [Voice(elements: [])]),
        Measure(voices: [Voice(elements: [])]),
    ])
    let part = Part(
        id: "1",
        instrument: Instrument(id: "x", longName: "Piano"),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])

    #expect(score.displayedMeasureNumber(at: 0) == nil)
    #expect(score.displayedMeasureNumber(at: 1) == 1)
    #expect(score.displayedMeasureNumber(at: 2) == 2)

    let regular = Score(division: 480, parts: [Part(
        id: "1",
        instrument: Instrument(id: "x", longName: "Piano"),
        staves: [Staff(measures: [
            Measure(voices: [Voice(elements: [])]),
            Measure(voices: [Voice(elements: [])]),
        ])]
    )])
    #expect(regular.displayedMeasureNumber(at: 0) == 1)
    #expect(regular.displayedMeasureNumber(at: 1) == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnacrusisTests`
Expected: compile error — `displayedMeasureNumber(at:)` undefined on `Score`.

- [ ] **Step 3: Implement the helper**

Create `Sources/SheetMusicCore/Score/Score+MeasureNumber.swift`:

```swift
import Foundation

extension Score {
    /// 1-based displayed measure number, with `irregular` measures
    /// excluded from the running count. Returns `nil` for an irregular
    /// measure (no label drawn).
    ///
    /// Uses staff 0 as the source of truth for `irregular`. Per-staff
    /// divergence is out of scope for this version.
    public func displayedMeasureNumber(at index: Int) -> Int? {
        guard let staff = allStaves.first?.staff,
              staff.measures.indices.contains(index)
        else { return nil }
        if staff.measures[index].irregular { return nil }
        var count = 0
        for i in 0 ... index where !staff.measures[i].irregular {
            count += 1
        }
        return count
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AnacrusisTests`
Expected: PASS.

Run: `swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Score+MeasureNumber.swift \
        Tests/SheetMusicTests/AnacrusisTests.swift
git commit -m "feat(core): Score.displayedMeasureNumber(at:) helper"
```

---

## Task 3: MSCX decoder reads `len` and `<irregular>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Measure.swift`
- Test: `Tests/SheetMusicTests/AnacrusisTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to the suite:

```swift
@Test func decodesLenAttributeAndIrregularElement() throws {
    let mscx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="4.60">
      <Score>
        <Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="x"><longName>X</longName></Instrument>
        </Part>
        <Staff id="1">
          <Measure len="1/4">
            <irregular>1</irregular>
            <voice></voice>
          </Measure>
          <Measure>
            <voice></voice>
          </Measure>
        </Staff>
      </Score>
    </museScore>
    """
    let score = try MSCXParser.parse(Data(mscx.utf8))
    let measures = score.parts[0].staves[0].measures
    #expect(measures[0].actualLength == Fraction(numerator: 1, denominator: 4))
    #expect(measures[0].irregular == true)
    #expect(measures[1].actualLength == nil)
    #expect(measures[1].irregular == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnacrusisTests`
Expected: FAIL on the first `#expect` — decoded `actualLength` is still `nil`.

- [ ] **Step 3: Update the decoder**

Edit `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Measure.swift` `decode(_:)` to read both fields. Replace the existing function with:

```swift
extension Measure {
    static func decode(_ node: XMLTreeNode) throws -> Measure {
        let startRepeat = node.children.contains(where: { $0.name == "startRepeat" })
        let endRepeatCount = node.first("endRepeat").flatMap { Int($0.text) }
        let measureRepeatCount = node.first("measureRepeatCount").flatMap { Int($0.text) }

        let voiceNodes = node.all("voice")
        let voices: [Voice]
        if !voiceNodes.isEmpty {
            voices = try voiceNodes.map { try Voice.decode($0) }
        } else {
            // Older / simpler mscx form: musical elements are direct children of
            // <Measure> (no <voice> wrapper). Treat them as a single implicit voice.
            voices = try [Voice.decode(node)]
        }
        let markers = node.all("Marker").map(decodeMarker)
        let jumps = node.all("Jump").map(decodeJump)
        var lineBreak = false
        var pageBreak = false
        for lb in node.all("LayoutBreak") {
            switch lb.first("subtype")?.text {
            case "line": lineBreak = true
            case "page": pageBreak = true
            default: break
            }
        }

        // `<Measure len="N/D">`. Malformed values fall back to nil — the
        // parser stays permissive about optional metadata.
        let actualLength = node.attributes["len"].flatMap(Fraction.init(mscxString:))
        // `<irregular>1</irregular>`.
        let irregular = node.first("irregular")?.text == "1"

        return Measure(
            voices: voices,
            startRepeat: startRepeat,
            endRepeatCount: endRepeatCount,
            measureRepeatCount: measureRepeatCount,
            markers: markers,
            jumps: jumps,
            lineBreak: lineBreak,
            pageBreak: pageBreak,
            actualLength: actualLength,
            irregular: irregular
        )
    }

    private static func decodeMarker(_ node: XMLTreeNode) -> Marker {
        let markerType = node.first("markerType")?.text ?? ""
        let label = node.first("label")?.text ?? ""
        let text = node.first("text")?.text ?? ""
        return Marker(
            kind: Marker.Kind(rawValue: markerType) ?? .other,
            label: label,
            text: text
        )
    }

    private static func decodeJump(_ node: XMLTreeNode) -> Jump {
        Jump(
            jumpTo: node.first("jumpTo")?.text ?? "",
            playUntil: node.first("playUntil")?.text ?? "",
            continueAt: node.first("continueAt")?.text ?? "",
            text: node.first("text")?.text ?? ""
        )
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AnacrusisTests`
Expected: PASS.

Run: `swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Measure.swift \
        Tests/SheetMusicTests/AnacrusisTests.swift
git commit -m "feat(mscx): decode <Measure len> and <irregular> on Measure"
```

---

## Task 4: MSCX encoder emits `len` and `<irregular>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`
- Test: `Tests/SheetMusicTests/AnacrusisTests.swift` (append)

- [ ] **Step 1: Write the failing test (round-trip)**

Append to the suite:

```swift
@Test func mscxRoundTripsAnacrusisFields() throws {
    // Hand-build a tiny score with an irregular pickup measure, then
    // encode and decode through MSCX and confirm the two new fields
    // survive byte-for-byte.
    let pickup = Measure(
        voices: [Voice(elements: [])],
        actualLength: Fraction(numerator: 1, denominator: 4),
        irregular: true
    )
    let normal = Measure(voices: [Voice(elements: [])])
    let staff = Staff(measures: [pickup, normal])
    let part = Part(
        id: "1",
        instrument: Instrument(id: "x", longName: "Piano"),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])

    let data = try MSCXEncoder.encode(score)
    let decoded = try MSCXParser.parse(data)
    let roundTripped = decoded.parts[0].staves[0].measures
    #expect(roundTripped[0].actualLength == Fraction(numerator: 1, denominator: 4))
    #expect(roundTripped[0].irregular == true)
    #expect(roundTripped[1].actualLength == nil)
    #expect(roundTripped[1].irregular == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnacrusisTests`
Expected: FAIL — encoder emits no `len` attribute, no `<irregular>` element, so the decoded measure has the defaults.

- [ ] **Step 3: Update the encoder**

Edit `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`. In the `encode(carryInVoiceTieCarries:isFirstMeasureOfStaff:options:staffGroup:)` method, two changes:

(a) After the existing `<startRepeat/>` block and before the voice-encoding loop, emit `<irregular>` when set:

```swift
        if startRepeat {
            children.append(XMLTreeNode(name: "startRepeat"))
        }
        if irregular {
            children.append(XMLTreeNode(name: "irregular", text: "1"))
        }
```

(b) When constructing the `<Measure>` root node at the bottom of the function, populate its `attributes` dictionary with `len` if `actualLength` is set. Replace:

```swift
        return (
            XMLTreeNode(name: "Measure", children: children),
            carryOut
        )
```

with:

```swift
        var attributes: [String: String] = [:]
        if let actualLength {
            attributes["len"] = "\(actualLength.numerator)/\(actualLength.denominator)"
        }
        return (
            XMLTreeNode(name: "Measure", attributes: attributes, children: children),
            carryOut
        )
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AnacrusisTests`
Expected: PASS.

Run: `swift test`
Expected: all green.

If a fixture-equivalence test (e.g. an MSCX golden-file diff in another suite) flags an unrelated change, double-check that you only added attributes/children on measures with the new fields set — measures without them must serialize identically to before.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift \
        Tests/SheetMusicTests/AnacrusisTests.swift
git commit -m "feat(mscx): encode <Measure len> attribute and <irregular>"
```

---

## Task 5: Layout suppresses numbering on irregular measures

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`
- Test: `Tests/SheetMusicTests/AnacrusisTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to the suite:

```swift
@available(macOS 15.0, iOS 16.0, *)
@Test func layoutSkipsMeasureNumberOnIrregularMeasures() throws {
    // 3-measure single-staff score; measure 0 is irregular.
    let irregular = Measure(voices: [Voice(elements: [])], irregular: true)
    let m1 = Measure(voices: [Voice(elements: [])])
    let m2 = Measure(voices: [Voice(elements: [])])
    let staff = Staff(measures: [irregular, m1, m2])
    let part = Part(
        id: "1",
        instrument: Instrument(id: "x", longName: "Piano"),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])

    // Sticky header path: per-measure context label. nil for measure 0,
    // 1 for measure 1, 2 for measure 2.
    let contexts = LayoutEngine.measureContexts(for: score)
    #expect(contexts[0].displayedMeasureNumber == nil)
    #expect(contexts[1].displayedMeasureNumber == 1)
    #expect(contexts[2].displayedMeasureNumber == 2)

    // Per-system head label path: build a layout document and scan
    // each measure's markers for `.measureNumber`.
    let document = LayoutEngine.layout(
        score: score, options: .init(), availableWidth: 800
    )
    let measures = document.systems.flatMap(\.measures)
    func numberLabel(at index: Int) -> String? {
        guard let m = measures.first(where: { $0.measureIndex == index })
        else { return nil }
        for marker in m.markers {
            if case let .measureNumber(text, _) = marker { return text }
        }
        return nil
    }
    #expect(numberLabel(at: 0) == nil)
    #expect(numberLabel(at: 1) == "1")
    #expect(numberLabel(at: 2) == "2")
}
```

The `LayoutEngine.layout(score:options:availableWidth:)` entry-point name matches the call pattern in `Tests/SheetMusicTests/LayoutEngineTests.swift`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnacrusisTests`
Expected: compile error — `LayoutMeasureContext` has no `displayedMeasureNumber` property.

- [ ] **Step 3: Add the field to `LayoutMeasureContext` and populate it**

Edit `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift`. Update the struct:

```swift
public struct LayoutMeasureContext: Sendable, Equatable {
    public let measureIndex: Int
    public let clefRawTypes: [String]
    public let keySignatures: [Int]
    public let timeSignature: TimeSignaturePair?
    public let partLabels: [String]
    /// 1-based displayed number for this measure, with irregular
    /// measures excluded. `nil` when this measure is irregular and no
    /// number should be drawn.
    public let displayedMeasureNumber: Int?

    public struct TimeSignaturePair: Sendable, Equatable {
        public let numerator: Int
        public let denominator: Int
        public init(numerator: Int, denominator: Int) {
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    public init(
        measureIndex: Int,
        clefRawTypes: [String],
        keySignatures: [Int],
        timeSignature: TimeSignaturePair?,
        partLabels: [String],
        displayedMeasureNumber: Int? = nil
    ) {
        self.measureIndex = measureIndex
        self.clefRawTypes = clefRawTypes
        self.keySignatures = keySignatures
        self.timeSignature = timeSignature
        self.partLabels = partLabels
        self.displayedMeasureNumber = displayedMeasureNumber
    }
}
```

In the same file, update the `contexts.append(...)` call in `measureContexts(for:)` to pass the new field:

```swift
            contexts.append(LayoutMeasureContext(
                measureIndex: measureIdx,
                clefRawTypes: clefs,
                keySignatures: keys,
                timeSignature: timeSig,
                partLabels: partLabels,
                displayedMeasureNumber: score.displayedMeasureNumber(at: measureIdx)
            ))
```

In the same file, change the sticky-header marker emission so it skips when `displayedMeasureNumber` is `nil`. Locate the block at lines ~278-298 (`var markers: [LayoutElement] = [] … markers.append(.measureNumber(...))`) and replace with:

```swift
        var markers: [LayoutElement] = []
        if let topStaffOrigin = staffOrigins.first,
           let displayed = context.displayedMeasureNumber {
            // Sticky measure number, MuseScore-style:
            //   - "#N" prefix (continuouspanel.cpp:420 emits
            //     `String(u"#%1").arg(currentMeasure->measureNumber()
            //     + 1)`).
            //   - Irregular measures (anacrusis) get no label, matching
            //     MuseScore's measure-numbering rule.
            markers.append(.measureNumber(
                text: "#\(displayed)",
                origin: CGPoint(
                    x: labelX,
                    y: topStaffOrigin.y - metrics.sp * 2.5
                )
            ))
        }
```

- [ ] **Step 4: Update the per-system head label**

Edit `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`. Locate the block at lines ~539-548 (`if j == 0, !staves.isEmpty { … markers.append(.measureNumber(...)) }`) and replace with:

```swift
            if j == 0, !staves.isEmpty,
               let displayed = context.score
                   .displayedMeasureNumber(at: measureIdx)
            {
                let staffTopY = staffOrigins[0].y
                markers.append(.measureNumber(
                    text: "\(displayed)",
                    origin: CGPoint(
                        x: -metrics.sp * 0.5,
                        y: staffTopY - metrics.sp * 1.5
                    )
                ))
            }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter AnacrusisTests`
Expected: PASS.

Run: `swift test`
Expected: all green. The other layout tests build scores with no irregular measures, so `displayedMeasureNumber(at: i)` returns `i + 1` for them — unchanged behaviour.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift \
        Tests/SheetMusicTests/AnacrusisTests.swift
git commit -m "feat(layout): skip measure number on irregular measures"
```

---

## Wrap-up

- [ ] **Run the full suite once more**

Run: `swift test`
Expected: all 12 (or 13 with the new suite) suites green, total test count up by 5.

- [ ] **Lint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings, 0 errors.

- [ ] **Final review**

```bash
git log --oneline -6
git diff main...HEAD --stat
```

Expected: 5 feature commits (one per task), all green CI signals.
