# Hairpin MIDI velocity ramp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `<HairPin>` cresc. / decresc. spanners drive a per-note velocity ramp during MIDI render so the in-between notes get linearly interpolated velocities, instead of being silently skipped.

**Architecture:** Extend `Spanner` with an optional `HairpinPayload` (subtype + `<veloChange>` + curve method). At render time, a per-voice pre-pass (`HairpinRamps.collect`) walks original (pre-repeat) ticks once to resolve each hairpin into a `HairpinRamp` with concrete start/end velocities — preferring bracket Dynamics, falling back to `<veloChange>`, finally to a hard ±10 default. `MidiRenderer+Voice` translates each chord's playback tick back to its original tick and overrides the chord-onset velocity when a ramp is active. `<TextLine>` cresc., Single Note Dynamics CCs, and non-linear curves are explicitly out of scope (decoded but linear-only).

**Tech Stack:** Swift 5.9 / Swift Testing (`@Test`, `#expect`); SwiftPM; the existing `SheetMusicCore` / `SheetMusicMSCX` / `SheetMusicMIDI` library boundary; MuseScore's `<HairPin>` MSCX schema.

**Source spec:** `docs/superpowers/specs/2026-05-09-hairpin-midi-velocity-ramp-design.md`.

**Reading order for an engineer with no prior context:**

- `Sources/SheetMusicCore/Score/Spanner.swift` — the type we're extending
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift` and the matching encoder
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — `renderVoice` / `renderVoiceElement`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Repeats.swift` — `playbackPlan`, `measureTicks`
- `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift` — gets a new option
- `Tests/SheetMusicTests/MidiExportTests.swift` — pattern for fixture-driven cases

---

## File Structure

**Create:**

- `Sources/SheetMusicMIDI/Render/HairpinRamps.swift` — `HairpinRamp` value type, `enum HairpinRamps` namespace with `collect / interpolate / active` static methods
- `Tests/SheetMusicTests/HairpinRampsTests.swift` — pure unit tests for `collect / interpolate`
- `Tests/SheetMusicTests/HairpinMidiTests.swift` — fixture-driven semantic-equivalence test
- `Tests/SheetMusicTests/Resources/testSingleNoteDynamics.mscx` — GPL-3.0 upstream fixture (test target only)
- `Tests/SheetMusicTests/Resources/testSingleNoteDynamics-ref.mid` — paired reference

**Modify:**

- `Sources/SheetMusicCore/Score/Spanner.swift` — add `HairpinPayload` nested type and `hairpin: HairpinPayload?` field
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift` — populate `hairpin` when `kind == .hairpin`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift` — emit `<subtype>` / `<veloChange>` / `<veloChangeMethod>` inside the `<HairPin>` payload child
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — call `HairpinRamps.collect` once per voice; build `originalMeasureBase`; override chord-onset velocity in the `.chord` arm
- `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift` — add `MidiSemanticComparisonOptions` (with `ignoreTempoNoise` / `ignoreControlChange`) and a new `assertEquivalent(produced:reference:options:)` overload; existing call sites unchanged
- `Tests/SheetMusicTests/Resources/LICENSE` — list the new fixture under MuseScore-derived files
- (Optional, end of plan) `MEMORY.md` entry update for `feature_gaps_checklist`

---

## Task 1: Add `HairpinPayload` to `Spanner`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Spanner.swift`
- Test: `Tests/SheetMusicTests/HairpinPayloadTests.swift` (new file in this task)

This task adds the data type only. Decoding, encoding, and rendering land in later tasks. We start with a public-API-compatible field with a default `nil`, so the rest of the codebase keeps building.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/HairpinPayloadTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite struct HairpinPayloadTests {
    @Test func defaultSpannerHasNilHairpin() {
        let s = Spanner(kind: .hairpin, rawType: "HairPin")
        #expect(s.hairpin == nil)
    }

    @Test func payloadEqualityRespectsAllFields() {
        let a = Spanner.HairpinPayload(
            subtype: .crescendo,
            veloChange: 20,
            veloChangeMethod: .normal
        )
        let b = Spanner.HairpinPayload(
            subtype: .crescendo,
            veloChange: 20,
            veloChangeMethod: .normal
        )
        let c = Spanner.HairpinPayload(
            subtype: .decrescendo,
            veloChange: 20,
            veloChangeMethod: .normal
        )
        #expect(a == b)
        #expect(a != c)
    }

    @Test func subtypeRawValuesMatchMuseScore() {
        #expect(Spanner.HairpinPayload.Subtype.crescendo.rawValue == 0)
        #expect(Spanner.HairpinPayload.Subtype.decrescendo.rawValue == 1)
    }

    @Test func veloChangeMethodFromXMLString() {
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "normal") == .normal)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-in") == .easeIn)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-out") == .easeOut)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-in-out") == .easeInOut)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "exponential") == .exponential)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HairpinPayloadTests`
Expected: build failure — `'HairpinPayload' is not a member type of 'Spanner'`.

- [ ] **Step 3: Add the nested type and field**

Edit `Sources/SheetMusicCore/Score/Spanner.swift`. Add `hairpin` to the stored properties and to the initializer (defaulting to `nil`). Append the nested type at the end of the `Spanner` struct, before the closing brace:

```swift
public var hairpin: HairpinPayload?

public init(
    kind: Kind,
    rawType: String,
    nextMeasuresOffset: Int = 0,
    nextFractionsOffset: Fraction? = nil,
    voltaEndings: [Int] = [],
    visible: Bool = true,
    hairpin: HairpinPayload? = nil
) {
    self.kind = kind
    self.rawType = rawType
    self.nextMeasuresOffset = nextMeasuresOffset
    self.nextFractionsOffset = nextFractionsOffset
    self.voltaEndings = voltaEndings
    self.visible = visible
    self.hairpin = hairpin
}

/// MuseScore `<HairPin>` payload needed for MIDI playback.
/// Meaningful only when `kind == .hairpin`. Nil for other kinds.
/// C++: `mu::engraving::Hairpin`.
public struct HairpinPayload: Sendable, Equatable {
    public enum Subtype: Int, Sendable {
        case crescendo = 0
        case decrescendo = 1
    }

    /// Linear / ease curve. v1 implements `.normal` (linear) only;
    /// other cases fall through to linear in `HairpinRamps.interpolate`.
    public enum VeloChangeMethod: String, Sendable {
        case normal
        case easeIn = "ease-in"
        case easeOut = "ease-out"
        case easeInOut = "ease-in-out"
        case exponential
    }

    public var subtype: Subtype
    /// `<veloChange>` value (1..127). Used when bracket Dynamics
    /// don't pin both endpoints. MuseScore's default of 0 is
    /// normalised to nil at decode time.
    public var veloChange: Int?
    public var veloChangeMethod: VeloChangeMethod

    public init(
        subtype: Subtype,
        veloChange: Int? = nil,
        veloChangeMethod: VeloChangeMethod = .normal
    ) {
        self.subtype = subtype
        self.veloChange = veloChange
        self.veloChangeMethod = veloChangeMethod
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HairpinPayloadTests`
Expected: 4 tests pass.

- [ ] **Step 5: Run the full suite to verify no regression**

Run: `swift test`
Expected: 48 + 4 = 52 tests pass (was 48). Spanner's added optional default keeps every existing call site working.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Score/Spanner.swift \
        Tests/SheetMusicTests/HairpinPayloadTests.swift
git commit -m "core: add Spanner.HairpinPayload (subtype, veloChange, method)"
```

---

## Task 2: Decode `<HairPin>` payload

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift`
- Test: `Tests/SheetMusicTests/HairpinDecoderTests.swift` (new file)

The decoder populates `hairpin` only when `kind == .hairpin`. Default-equivalent XML (`<subtype>0</subtype>`, `<veloChange>0</veloChange>`, missing `<veloChangeMethod>`) must round-trip to non-nil-but-defaulted values, since the MSCX file still contains the `<HairPin/>` payload child even when those tags are absent.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/HairpinDecoderTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct HairpinDecoderTests {
    private func decode(_ xml: String) throws -> Spanner {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Spanner.decode(node)
    }

    @Test func crescendoMinimalPayload() throws {
        let s = try decode(#"<Spanner type="HairPin"><HairPin/></Spanner>"#)
        #expect(s.kind == .hairpin)
        #expect(s.hairpin?.subtype == .crescendo)
        #expect(s.hairpin?.veloChange == nil)
        #expect(s.hairpin?.veloChangeMethod == .normal)
    }

    @Test func decrescendoExplicitSubtype() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><subtype>1</subtype></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.subtype == .decrescendo)
    }

    @Test func veloChangeZeroIsNormalisedToNil() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChange>0</veloChange></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChange == nil)
    }

    @Test func veloChangePositive() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChange>20</veloChange></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChange == 20)
    }

    @Test func veloChangeMethodEaseIn() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChangeMethod>ease-in</veloChangeMethod></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChangeMethod == .easeIn)
    }

    @Test func unknownMethodFallsBackToNormal() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChangeMethod>quintic</veloChangeMethod></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChangeMethod == .normal)
    }

    @Test func nonHairpinHasNilHairpin() throws {
        let s = try decode(#"<Spanner type="Slur"><Slur/></Spanner>"#)
        #expect(s.kind == .slur)
        #expect(s.hairpin == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HairpinDecoderTests`
Expected: 7 tests fail — `s.hairpin` is always nil because the decoder doesn't populate it yet.

- [ ] **Step 3: Update the decoder**

Edit `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift`. Inside `decode(_:)`, after `nextFractions` is computed and before the `return Spanner(…)` call, add:

```swift
var hairpin: Spanner.HairpinPayload?
if kind == .hairpin, let hp = node.first("HairPin") {
    let subtypeRaw = Int(hp.first("subtype")?.text ?? "0") ?? 0
    let subtype = Spanner.HairpinPayload.Subtype(rawValue: subtypeRaw) ?? .crescendo

    let veloChangeText = hp.first("veloChange")?.text
    let veloChangeRaw = veloChangeText.flatMap(Int.init)
    let veloChange = veloChangeRaw == 0 ? nil : veloChangeRaw

    let methodRaw = hp.first("veloChangeMethod")?.text ?? ""
    let method = Spanner.HairpinPayload.VeloChangeMethod(rawValue: methodRaw) ?? .normal

    hairpin = Spanner.HairpinPayload(
        subtype: subtype,
        veloChange: veloChange,
        veloChangeMethod: method
    )
}
```

Then add `hairpin: hairpin,` to the `Spanner(…)` initializer call (after `visible:`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HairpinDecoderTests`
Expected: 7 tests pass.

- [ ] **Step 5: Run the full suite to verify no regression**

Run: `swift test`
Expected: 52 + 7 = 59 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift \
        Tests/SheetMusicTests/HairpinDecoderTests.swift
git commit -m "mscx: decode <HairPin> subtype/veloChange/veloChangeMethod"
```

---

## Task 3: Encode `<HairPin>` payload

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`
- Test: `Tests/SheetMusicTests/HairpinEncoderTests.swift` (new file)

Round-trip the same fields the decoder reads. Tags equal to MuseScore defaults are omitted: no `<veloChange>` when `nil`, no `<veloChangeMethod>` when `.normal`. `<subtype>` is always written when `hairpin != nil` so the encoded stream is unambiguous (matches MuseScore's writer, which never omits `<subtype>` from a `<HairPin>` element).

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/HairpinEncoderTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct HairpinEncoderTests {
    @Test func nilHairpinEmitsBareElement() {
        let s = Spanner(kind: .hairpin, rawType: "HairPin")
        let node = s.encode()
        #expect(node.first("HairPin") != nil)
        #expect(node.first("HairPin")?.first("subtype") == nil)
        #expect(node.first("HairPin")?.first("veloChange") == nil)
        #expect(node.first("HairPin")?.first("veloChangeMethod") == nil)
    }

    @Test func crescendoWithVeloChange() {
        let s = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            hairpin: .init(subtype: .crescendo, veloChange: 20)
        )
        let hp = s.encode().first("HairPin")
        #expect(hp?.first("subtype")?.text == "0")
        #expect(hp?.first("veloChange")?.text == "20")
        #expect(hp?.first("veloChangeMethod") == nil) // .normal omitted
    }

    @Test func decrescendoEaseInOut() {
        let s = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            hairpin: .init(subtype: .decrescendo, veloChangeMethod: .easeInOut)
        )
        let hp = s.encode().first("HairPin")
        #expect(hp?.first("subtype")?.text == "1")
        #expect(hp?.first("veloChange") == nil)
        #expect(hp?.first("veloChangeMethod")?.text == "ease-in-out")
    }

    @Test func roundTripPreservesPayload() throws {
        let original = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 1,
            hairpin: .init(subtype: .crescendo, veloChange: 15, veloChangeMethod: .easeIn)
        )
        let encoded = original.encode()
        let xml = encoded.serialize()
        let reparsed = try XMLTreeParser.parse(Data(xml.utf8))
        let decoded = try Spanner.decode(reparsed)
        #expect(decoded.kind == .hairpin)
        #expect(decoded.hairpin?.subtype == .crescendo)
        #expect(decoded.hairpin?.veloChange == 15)
        #expect(decoded.hairpin?.veloChangeMethod == .easeIn)
        #expect(decoded.nextMeasuresOffset == 1)
    }
}
```

If `XMLTreeNode.serialize()` is named differently in this codebase, replace the round-trip test with `let _ = encoded` and assert via the in-memory tree only — the first three tests already cover the encoder's contract. Verify the actual API name with `grep -n "func serialize\|public func.*String" Sources/SheetMusicXMLTools/`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HairpinEncoderTests`
Expected: 4 tests fail — encoder still emits `<HairPin/>` empty regardless of payload.

- [ ] **Step 3: Update the encoder**

Edit `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`. Replace the `payloadElement(options:)` body to write the `<HairPin>` payload children when `hairpin != nil`:

```swift
private func payloadElement(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
    if kind == .volta, !voltaEndings.isEmpty {
        let endingsText = voltaEndings.map(String.init).joined(separator: ", ")
        return XMLTreeNode(name: rawType, children: [
            XMLTreeNode(name: "endings", text: endingsText),
        ])
    }
    if kind == .hairpin, let hairpin {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: String(hairpin.subtype.rawValue)),
        ]
        if let velo = hairpin.veloChange {
            children.append(XMLTreeNode(name: "veloChange", text: String(velo)))
        }
        if hairpin.veloChangeMethod != .normal {
            children.append(XMLTreeNode(
                name: "veloChangeMethod",
                text: hairpin.veloChangeMethod.rawValue
            ))
        }
        return XMLTreeNode(name: rawType, children: children)
    }
    return XMLTreeNode(name: rawType)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HairpinEncoderTests`
Expected: 4 tests pass.

- [ ] **Step 5: Run the full suite to verify no regression**

Run: `swift test`
Expected: 59 + 4 = 63 tests pass. No existing fixture round-trip should change because previous fixtures don't carry `<HairPin>` payload tags — the empty `<HairPin/>` element is preserved when `hairpin == nil`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift \
        Tests/SheetMusicTests/HairpinEncoderTests.swift
git commit -m "mscx: encode <HairPin> subtype/veloChange/veloChangeMethod"
```

---

## Task 4: `HairpinRamps` value type and pre-pass

**Files:**
- Create: `Sources/SheetMusicMIDI/Render/HairpinRamps.swift`
- Test: `Tests/SheetMusicTests/HairpinRampsTests.swift`

The pre-pass walks one voice in original (pre-repeat) ticks once, collects pending hairpins and dynamics, then resolves each hairpin's end velocity by preferring a Dynamic at-or-after the hairpin's end tick over `<veloChange>` over a hard ±10 default. `interpolate` is linear; `active` returns the latest-starting ramp containing a tick (defensive against unlikely overlaps). Velocities passed in/out are already articulation-scaled via `MidiRenderer.effectiveVelocity` so the renderer can substitute the result directly.

- [ ] **Step 1: Write the failing test for `interpolate`**

Create `Tests/SheetMusicTests/HairpinRampsTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct HairpinRampsTests {
    private func ramp(
        startTick: Int = 0,
        endTick: Int = 480,
        startVelocity: Int = 60,
        endVelocity: Int = 112,
        method: Spanner.HairpinPayload.VeloChangeMethod = .normal
    ) -> HairpinRamp {
        HairpinRamp(
            startTick: startTick,
            endTick: endTick,
            startVelocity: startVelocity,
            endVelocity: endVelocity,
            method: method
        )
    }

    @Test func interpolateLinearMidpoint() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 240) == 80)
    }

    @Test func interpolateClampsBeforeStart() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: -100) == 60)
    }

    @Test func interpolateClampsAfterEnd() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 1000) == 100)
    }

    @Test func interpolateSingleTickSpanReturnsEnd() {
        let r = ramp(startTick: 480, endTick: 480, startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 480) == 100)
    }

    @Test func nonNormalMethodsFallThroughToLinear() {
        for method: Spanner.HairpinPayload.VeloChangeMethod in
            [.easeIn, .easeOut, .easeInOut, .exponential]
        {
            let r = ramp(startVelocity: 60, endVelocity: 100, method: method)
            #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 240) == 80,
                    "method \(method) should fall through to linear in v1")
        }
    }

    @Test func activeReturnsLatestContainingRamp() {
        let r1 = ramp(startTick: 0, endTick: 480)
        let r2 = ramp(startTick: 240, endTick: 720)
        #expect(HairpinRamps.active(in: [r1, r2], at: 100)?.startTick == 0)
        #expect(HairpinRamps.active(in: [r1, r2], at: 300)?.startTick == 240)
        #expect(HairpinRamps.active(in: [r1, r2], at: 1000) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HairpinRampsTests`
Expected: build failure — `HairpinRamp` and `HairpinRamps` don't exist.

- [ ] **Step 3: Create the new file with skeleton + interpolate / active**

Create `Sources/SheetMusicMIDI/Render/HairpinRamps.swift`:

```swift
import Foundation
import SheetMusicCore

/// One resolved hairpin: a linear (or v1-falls-through-to-linear)
/// velocity ramp between two ticks in the original (pre-repeat)
/// score timeline. Built by `HairpinRamps.collect` and consumed by
/// `MidiRenderer+Voice` at chord onset.
struct HairpinRamp: Equatable {
    let startTick: Int
    let endTick: Int        // inclusive
    let startVelocity: Int  // already articulation-scaled
    let endVelocity: Int    // already articulation-scaled
    let method: Spanner.HairpinPayload.VeloChangeMethod
}

enum HairpinRamps {
    static let defaultDeltaVelocity = 10

    /// Linear interpolation. v1: non-`.normal` methods fall through
    /// to the linear branch — leaves an obvious extension point for
    /// future curve work.
    static func interpolate(ramp: HairpinRamp, atOriginalTick tick: Int) -> Int {
        if tick <= ramp.startTick { return ramp.startVelocity }
        if tick >= ramp.endTick { return ramp.endVelocity }
        let span = max(1, ramp.endTick - ramp.startTick)
        let progress = tick - ramp.startTick
        switch ramp.method {
        case .normal, .easeIn, .easeOut, .easeInOut, .exponential: // v1: linear-only
            let delta = ramp.endVelocity - ramp.startVelocity
            // Round-half-away-from-zero so symmetric cresc/decresc match.
            let scaled = delta * progress
            let rounded = (scaled + (scaled >= 0 ? span / 2 : -span / 2)) / span
            return ramp.startVelocity + rounded
        }
    }

    /// Latest-starting ramp containing `tick`. Well-formed scores
    /// don't overlap hairpins; this is a defensive choice.
    static func active(in ramps: [HairpinRamp], at tick: Int) -> HairpinRamp? {
        ramps
            .filter { tick >= $0.startTick && tick <= $0.endTick }
            .max(by: { $0.startTick < $1.startTick })
    }
}
```

- [ ] **Step 4: Run the per-function tests**

Run: `swift test --filter HairpinRampsTests`
Expected: the 7 cases above pass; `collect`-based cases (added below) are not yet present.

- [ ] **Step 5: Add `collect` API skeleton with `Pending` + resolve helper**

Append to `Sources/SheetMusicMIDI/Render/HairpinRamps.swift` inside the `enum HairpinRamps`:

```swift
    /// Walk one voice in original (pre-repeat) ticks and resolve every
    /// `<HairPin>` into a concrete `HairpinRamp`. End velocity priority:
    /// (a) a `Dynamic` whose original tick is at-or-after the hairpin's
    /// end tick, (b) `<veloChange>` from the payload, (c) ±10 default.
    /// Sign comes from the subtype (cresc → +, decresc → −) and the
    /// final velocity is clamped to `1...127`.
    static func collect(
        voiceIndex: Int,
        staff: Staff,
        instrument: Instrument,
        division: Int
    ) -> [HairpinRamp] {
        struct DynPoint { let tick: Int; let velocity: Int }
        struct Pending {
            let startTick: Int
            let endTick: Int
            let startVelocity: Int
            let payload: Spanner.HairpinPayload
        }

        var dynList: [DynPoint] = []
        var pending: [Pending] = []
        var runningVel = MidiRenderer.effectiveVelocity(
            forDynamic: nil, instrument: instrument
        )
        var measureBase = 0

        for measure in staff.measures {
            var runningTick = measureBase
            let measureTicks = MidiRenderer.measureTicks(
                measure: measure, division: division
            )
            // resolvedVoice would unroll measure-repeats, but for the
            // ramp pre-pass we read the literal voice — hairpins
            // inside a measure-repeat source apply each time the
            // group plays back, and the runtime override re-uses the
            // original tick anyway.
            guard voiceIndex < measure.voices.count else {
                measureBase += measureTicks
                continue
            }
            let voice = measure.voices[voiceIndex]
            for element in voice.elements {
                switch element {
                case let .dynamic(d):
                    let v = MidiRenderer.effectiveVelocity(
                        forDynamic: d, instrument: instrument
                    )
                    dynList.append(DynPoint(tick: runningTick, velocity: v))
                    runningVel = v
                case let .spanner(s) where s.kind == .hairpin:
                    let payload = s.hairpin ?? Spanner.HairpinPayload(subtype: .crescendo)
                    let endTick = computeEndTick(
                        startTick: runningTick,
                        measureBase: measureBase,
                        spanner: s,
                        measures: staff.measures,
                        division: division
                    )
                    pending.append(Pending(
                        startTick: runningTick,
                        endTick: endTick,
                        startVelocity: runningVel,
                        payload: payload
                    ))
                case let .chord(chord):
                    runningTick += chord.duration.ticks(division: division)
                case let .locationShift(delta):
                    runningTick += delta.ticks(division: division)
                default:
                    break
                }
            }
            measureBase += measureTicks
        }

        return pending.map { p -> HairpinRamp in
            let endVel: Int
            if let dyn = dynList.first(where: { $0.tick >= p.endTick }) {
                endVel = dyn.velocity
            } else {
                let delta = p.payload.veloChange ?? defaultDeltaVelocity
                let signed = p.payload.subtype == .crescendo ? delta : -delta
                endVel = max(1, min(127, p.startVelocity + signed))
            }
            return HairpinRamp(
                startTick: p.startTick,
                endTick: p.endTick,
                startVelocity: p.startVelocity,
                endVelocity: endVel,
                method: p.payload.veloChangeMethod
            )
        }
    }

    /// Hairpin end tick = (start measure base + nextMeasures-worth of
    /// measure ticks) + nextFractions delta. When both offsets are
    /// zero we still need a usable end tick; default to start +
    /// remainder of the start measure (one beat fallback if even
    /// that is zero).
    private static func computeEndTick(
        startTick: Int,
        measureBase: Int,
        spanner: Spanner,
        measures: [Measure],
        division: Int
    ) -> Int {
        var endMeasureBase = measureBase
        let startMeasureIndex = indexOfMeasure(forBase: measureBase, in: measures, division: division)
        let lastIndex = min(
            measures.count - 1,
            startMeasureIndex + max(0, spanner.nextMeasuresOffset)
        )
        for i in startMeasureIndex ..< lastIndex {
            endMeasureBase += MidiRenderer.measureTicks(
                measure: measures[i], division: division
            )
        }
        let fractionDelta = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
        let computed = endMeasureBase + fractionDelta
        if computed > startTick { return computed }
        // Defensive fallback: a zero-length hairpin makes no audible
        // difference but interpolate's clamp would still yield a
        // valid number; pick start+1 to keep `endTick > startTick`.
        return startTick + 1
    }

    private static func indexOfMeasure(
        forBase base: Int, in measures: [Measure], division: Int
    ) -> Int {
        var acc = 0
        for (i, m) in measures.enumerated() {
            if acc == base { return i }
            acc += MidiRenderer.measureTicks(measure: m, division: division)
        }
        return max(0, measures.count - 1)
    }
}
```

Note on `MidiRenderer.measureTicks` and `MidiRenderer.effectiveVelocity`: both are declared `static` inside `extension MidiRenderer` in the project. They have `internal` access. Because `HairpinRamps.swift` lives in the same module (`SheetMusicMIDI`), the cross-file calls compile without further annotation. If a future refactor moves `HairpinRamps` to a different target, lift those helpers to `internal` named members of a shared utility type.

- [ ] **Step 6: Add the `collect`-driven test cases**

Append to `Tests/SheetMusicTests/HairpinRampsTests.swift`. These build hand-shaped `Score` values via the existing public initializers — keep each fixture small.

```swift
@Suite struct HairpinRampsCollectTests {
    private let division = 480

    private let pianoInstrument = Instrument(
        // Adapt this initializer to the project's actual signature;
        // reuse whatever helper the existing MidiRenderer tests use,
        // or hand-construct an Instrument with no articulations
        // (defaultArticulationVelocityScale falls back to 100).
        articulations: []
    )

    private func mp() -> Dynamic { Dynamic(name: "mp", velocity: 64) }
    private func f() -> Dynamic { Dynamic(name: "f", velocity: 96) }
    private func p() -> Dynamic { Dynamic(name: "p", velocity: 49) }

    private func quarter() -> Chord {
        Chord(notes: [Note(pitch: 60)], duration: Fraction(1, 4))
    }

    private func makeMeasure(_ elements: [VoiceElement]) -> Measure {
        Measure(voices: [Voice(elements: elements)])
    }

    private func staff(_ measures: [Measure]) -> Staff {
        Staff(measures: measures)
    }

    private func cresc(measures: Int = 1) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .crescendo)
        )
    }

    private func decresc(measures: Int = 1) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .decrescendo)
        )
    }

    @Test func bracketDynamicsOnBothSides() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
            makeMeasure([
                .dynamic(f()),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: pianoInstrument, division: division
        )
        #expect(ramps.count == 1)
        #expect(ramps.first?.startVelocity == 64)
        #expect(ramps.first?.endVelocity == 96)
    }

    @Test func noBracketUsesVeloChange() {
        let cresc20 = Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: 1,
            hairpin: .init(subtype: .crescendo, veloChange: 20)
        )
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc20),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
            makeMeasure([.chord(quarter()), .chord(quarter()), .chord(quarter()), .chord(quarter())]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: pianoInstrument, division: division
        )
        #expect(ramps.first?.endVelocity == 84) // 64 + 20
    }

    @Test func noBracketNoVeloChangeUsesDefaultDelta() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
            makeMeasure([.chord(quarter()), .chord(quarter()), .chord(quarter()), .chord(quarter())]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: pianoInstrument, division: division
        )
        #expect(ramps.first?.endVelocity == 64 + HairpinRamps.defaultDeltaVelocity)
    }

    @Test func decrescendoSign() {
        let s = staff([
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
            makeMeasure([
                .dynamic(p()),
                .chord(quarter()), .chord(quarter()), .chord(quarter()), .chord(quarter()),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: pianoInstrument, division: division
        )
        #expect(ramps.first?.startVelocity == 96)
        #expect(ramps.first?.endVelocity == 49)
        #expect(ramps.first?.endVelocity ?? 99 < ramps.first?.startVelocity ?? 0)
    }

    @Test func backToBackHairpinsShareMiddleDynamic() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                .chord(quarter()), .chord(quarter()),
                .chord(quarter()), .chord(quarter()),
            ]),
            makeMeasure([
                .dynamic(p()),
                .chord(quarter()), .chord(quarter()), .chord(quarter()), .chord(quarter()),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: pianoInstrument, division: division
        )
        #expect(ramps.count == 2)
        #expect(ramps[0].endVelocity == 96)
        #expect(ramps[1].startVelocity == 96)
        #expect(ramps[1].endVelocity == 49)
    }
}
```

The `Instrument`, `Dynamic`, `Chord`, `Note`, `Voice`, `Measure`, `Staff`, and `Fraction` initializer signatures are project-specific. Confirm the actual signatures with `grep -n "public init" Sources/SheetMusicCore/Score/<TypeName>.swift` before writing the test, and adapt these calls to match — the assertions on ramp counts and velocity values are the contract, not the helper shape.

- [ ] **Step 7: Run all `HairpinRamps` tests**

Run: `swift test --filter HairpinRamps`
Expected: all `interpolate / active` and `collect` tests pass.

- [ ] **Step 8: Run the full suite to verify no regression**

Run: `swift test`
Expected: 63 + the new HairpinRamps tests all green; nothing else affected (renderer integration is the next task).

- [ ] **Step 9: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/HairpinRamps.swift \
        Tests/SheetMusicTests/HairpinRampsTests.swift
git commit -m "midi: HairpinRamps pre-pass and linear interpolator"
```

---

## Task 5: Renderer integration — chord-onset velocity override

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`
- Test: `Tests/SheetMusicTests/HairpinRendererIntegrationTests.swift` (new file)

`renderVoice` calls `HairpinRamps.collect` once per voice and builds an `originalMeasureBase[measureIndex]` array (cumulative original-measure ticks, ignoring repeats). Each entry's playback tick `entry.tickOffset` corresponds to original tick `originalMeasureBase[entry.measureIndex] + (localTick - entry.tickOffset)`. We thread that delta into `renderVoiceElement` so the `.chord` arm can compute `onsetOriginalTick` and override `velocity` only for that chord — the running `velocity` variable is untouched, so once the ramp ends a subsequent `.dynamic` Dynamic still drives behaviour normally.

- [ ] **Step 1: Write the failing integration test**

Create `Tests/SheetMusicTests/HairpinRendererIntegrationTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct HairpinRendererIntegrationTests {
    private func makeStaffWithCresc() -> Staff {
        let mp = Dynamic(name: "mp", velocity: 64)
        let f = Dynamic(name: "f", velocity: 96)
        let q = Chord(notes: [Note(pitch: 60)], duration: Fraction(1, 4))
        let cresc = Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: 1,
            hairpin: .init(subtype: .crescendo)
        )
        return Staff(measures: [
            Measure(voices: [Voice(elements: [
                .dynamic(mp), .spanner(cresc),
                .chord(q), .chord(q), .chord(q), .chord(q),
            ])]),
            Measure(voices: [Voice(elements: [
                .dynamic(f),
                .chord(q), .chord(q), .chord(q), .chord(q),
            ])]),
        ])
    }

    @Test func noteVelocitiesRampLinearly() {
        let staff = makeStaffWithCresc()
        let part = Part(
            instrument: Instrument(articulations: []),
            staves: [staff]
        )
        let (events, _) = MidiRenderer.renderVoice(
            voiceIndex: 0, staff: staff, part: part,
            channel: 0, division: 480
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        // 4 onsets in measure 1 ramp from 64 toward 96; chord at the
        // hairpin end (start of measure 2) is set by the bracket
        // Dynamic to 96 and is therefore exactly 96.
        #expect(velocities.first == 64)
        #expect(velocities[1] > 64)
        #expect(velocities[2] > velocities[1])
        #expect(velocities[3] > velocities[2])
        #expect(velocities[4] == 96)
        // Strictly monotonic across the ramp, no flat plateau.
        for i in 0 ..< 4 {
            #expect(velocities[i] < velocities[i + 1])
        }
    }
}
```

If `Part` / `Instrument` / `Voice` / `Measure` / `Staff` initializer signatures differ in the project, adapt the test to use the existing initializers — the contract under test is the strict-monotonic ramp from 64 to 96 across five chord onsets. Confirm signatures via `grep -n "public init" Sources/SheetMusicCore/Score/Part.swift` etc.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter HairpinRendererIntegrationTests`
Expected: fails — every chord onset still shows velocity == 64 because the renderer hasn't been wired to the pre-pass.

- [ ] **Step 3: Add the pre-pass call in `renderVoice`**

Edit `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`. Inside `renderVoice`, immediately after the `var swingState = initialSwing` line, insert:

```swift
        let hairpinRamps = HairpinRamps.collect(
            voiceIndex: voiceIndex,
            staff: staff,
            instrument: part.instrument,
            division: division
        )
        // Original-tick base for each measure index, used to map
        // playback ticks (which include unrolled repeats) back to
        // pre-repeat ticks for ramp lookup.
        var originalMeasureBase: [Int] = []
        do {
            var acc = 0
            for m in staff.measures {
                originalMeasureBase.append(acc)
                acc += measureTicks(measure: m, division: division)
            }
        }
```

Then in the `for entry in plan {` loop, just before the `for (elementIndex, element) in effectiveVoice.elements.enumerated() {` line, compute the delta:

```swift
            let originalTickDelta = originalMeasureBase[entry.measureIndex] - entry.tickOffset
```

Pass `hairpinRamps` and `originalTickDelta` into `renderVoiceElement`. Update the call site to add the two new arguments at the end:

```swift
                renderVoiceElement(
                    element,
                    elementIndex: elementIndex,
                    voiceElements: effectiveVoice.elements,
                    voiceTuplets: effectiveVoice.tuplets,
                    measures: staff.measures,
                    measureIndex: entry.measureIndex,
                    currentKey: currentKey,
                    localTick: &localTick,
                    velocity: &velocity,
                    currentTempoBps: &currentTempoBps,
                    swingState: &swingState,
                    voiceIndex: voiceIndex,
                    channel: channel,
                    instrument: part.instrument,
                    division: division,
                    events: &events,
                    hairpinRamps: hairpinRamps,
                    originalTickDelta: originalTickDelta
                )
```

- [ ] **Step 4: Update `renderVoiceElement` signature and `.chord` arm**

In the same file, extend `renderVoiceElement`'s parameter list with `hairpinRamps: [HairpinRamp]` and `originalTickDelta: Int` (both at the end). Inside the `case let .chord(chord):` arm (the non-empty one), compute the override after the `swingAdjustment` call but before `renderChordWithGraces`:

```swift
            let onsetOriginalTick = (localTick + adjust.onsetShift) + originalTickDelta
            let chordVelocity =
                HairpinRamps.active(in: hairpinRamps, at: onsetOriginalTick)
                    .map { HairpinRamps.interpolate(ramp: $0, atOriginalTick: onsetOriginalTick) }
                ?? velocity

            renderChordWithGraces(
                chord,
                tick: localTick + adjust.onsetShift,
                velocity: chordVelocity,
                channel: channel,
                instrument: instrument,
                tempoBps: currentTempoBps,
                division: division,
                glissandoEndPitch: glissandoEndPitch,
                currentKey: currentKey,
                events: &events,
                playedTicksOverride: adjust == .none
                    ? nil
                    : max(1, chordTicks + adjust.lengthDelta)
            )
```

**Important:** do not assign to the `velocity: inout Int` parameter from the ramp result. Hairpin influence is scoped to the chord onset; the next `.dynamic(d)` resets `velocity` normally so post-ramp playback continues at the bracket level.

If the existing `// swiftlint:disable function_body_length file_length` directive flags the new parameter count, also append `function_parameter_count` to that suppression — `renderVoiceElement`'s arity has been growing for a reason and adding this final pair stays consistent with the file's accepted style.

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `swift test --filter HairpinRendererIntegrationTests`
Expected: passes; velocities ramp strictly monotonically and the bracket-end chord lands at 96.

- [ ] **Step 6: Run the full suite to verify no regression**

Run: `swift test`
Expected: every test green. Existing fixtures (`midi01`–`midi03`, `testVoltaTemp`, `testVoltaDynamic`, `testRepeatsWithKeySigs`, `testMidiPort`, `testArpeggio`, `testMutedUnison`, `testMeasureRepeats`, `testInitialKeySigThenRepeatToMeas2`, `testRepeatsWithKeySigsExceptFirstMeas`) carry no `<HairPin>` payload, so `hairpinRamps` is empty and the renderer behaviour is byte-identical.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift \
        Tests/SheetMusicTests/HairpinRendererIntegrationTests.swift
git commit -m "midi: apply HairpinRamps to chord-onset velocity"
```

---

## Task 6: `MidiSemanticComparisonOptions`

**Files:**
- Modify: `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift`
- Test: existing `MidiExportTests` re-run as a regression check (no new test file)

Add `MidiSemanticComparisonOptions { ignoreTempoNoise; ignoreControlChange }` and an overload `assertEquivalent(produced:reference:options:)`. The legacy `assertEquivalent(produced:reference:)` keeps calling with `.init()` so every existing call site (12 cases in `MidiExportTests`) is unchanged.

`ignoreTempoNoise` is included because the spec's option struct lists it (and the existing normaliser already drops adjacent same-kind metas, so wiring `ignoreTempoNoise: false` is a no-op for now). The substantive new behaviour is `ignoreControlChange`: drop CC events from both produced and reference before comparison, scoped to the sub-flag — Single Note Dynamics in MuseScore's reference emits CC11 etc. that v1 does not.

- [ ] **Step 1: Write the option-driven test**

Append to `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift`-aware test file. (We don't need a new dedicated test file; reuse a small inline fixture.) Append to `Tests/SheetMusicTests/HairpinRendererIntegrationTests.swift`:

```swift
@Suite struct MidiSemanticComparisonOptionsTests {
    private func dataWith(events: [TimedMidiEvent]) -> Data {
        let track = MidiTrack(events: events + [TimedMidiEvent(tick: 0, event: .endOfTrack)])
        let file = MidiFile(format: 0, division: 480, tracks: [track])
        return MidiWriter.write(file)
    }

    @Test func ignoreControlChangeDropsBothSides() throws {
        let withCC = dataWith(events: [
            TimedMidiEvent(tick: 0, event: .controlChange(channel: 0, controller: 11, value: 80)),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
        ])
        let withoutCC = dataWith(events: [
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
        ])
        // Without the option this would fail; with the option it passes.
        try MidiSemanticComparison.assertEquivalent(
            produced: withoutCC,
            reference: withCC,
            options: .init(ignoreControlChange: true)
        )
    }
}
```

If the `MidiTrack` / `MidiFile` / `MidiWriter` APIs differ from the names above, replace this test with: take the produced bytes from a real `renderVoice` call (e.g. the integration test's staff above) as `withoutCC`, manually inject a CC event via `MidiWriter` round-trip, and assert with the option. The contract is "CC events are ignored on both sides when the flag is on".

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter MidiSemanticComparisonOptionsTests`
Expected: build failure — `assertEquivalent(produced:reference:options:)` does not exist.

- [ ] **Step 3: Add the options struct and overload**

Edit `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift`. Add at the top of the `enum MidiSemanticComparison`:

```swift
    struct Options {
        /// MuseScore's `tempomapWithPauses` restoration occasionally
        /// emits the same kind of meta event twice within ≤1 tick at
        /// section boundaries. The default normaliser already drops
        /// these; this flag is reserved for future tuning and is a
        /// no-op today (kept in the spec for API stability).
        var ignoreTempoNoise: Bool = false
        /// Drop control-change events from both produced and reference
        /// before comparing. Used for Single Note Dynamics (CC11 etc.)
        /// where the v1 implementation only does note-on velocity.
        var ignoreControlChange: Bool = false
    }
```

Refactor `assertEquivalent(produced:reference:)` to delegate:

```swift
    static func assertEquivalent(produced: Data, reference: Data) throws {
        try assertEquivalent(produced: produced, reference: reference, options: .init())
    }

    static func assertEquivalent(
        produced: Data, reference: Data, options: Options
    ) throws {
        let producedFile = try MidiReader.read(produced)
        let referenceFile = try MidiReader.read(reference)
        // … existing division / track-count guards …
        for (i, pair) in zip(producedFile.tracks, referenceFile.tracks).enumerated() {
            let (p, r) = pair
            let pn = normalize(p.events, options: options)
            let rn = normalize(r.events, options: options)
            // … unchanged firstDifference / Issue.record block …
        }
    }
```

Update `normalize` to accept and apply the option:

```swift
    private static func normalize(_ events: [TimedMidiEvent], options: Options) -> [TimedMidiEvent] {
        var filtered: [TimedMidiEvent] = []
        for event in events {
            if case let .controlChange(_, cc, _) = event.event {
                if options.ignoreControlChange { continue }
                if cc == 2 { continue } // existing rule: drop sndController
            }
            filtered.append(event)
        }
        // … rest unchanged …
    }
```

The internal recursive call sites of `normalize` (none today, but be on the lookout) and the existing call from the legacy `assertEquivalent` flow now route through the new overload via `Options()`.

- [ ] **Step 4: Run all tests to verify the option works and nothing regressed**

Run: `swift test --filter MidiSemanticComparison`
Expected: the new option test passes.

Run: `swift test`
Expected: the 12 `MidiExportTests` cases plus all the new ones still pass — the legacy entry point `assertEquivalent(produced:reference:)` calls through with default options and observes identical normalisation.

- [ ] **Step 5: Commit**

```bash
git add Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift \
        Tests/SheetMusicTests/HairpinRendererIntegrationTests.swift
git commit -m "test: MidiSemanticComparison.Options with ignoreControlChange"
```

---

## Task 7: Import the `testSingleNoteDynamics` GPL fixture

**Files:**
- Create: `Tests/SheetMusicTests/Resources/testSingleNoteDynamics.mscx`
- Create: `Tests/SheetMusicTests/Resources/testSingleNoteDynamics-ref.mid`
- Modify: `Tests/SheetMusicTests/Resources/LICENSE`

These come from `MuseScore/src/importexport/midi/tests/midiexport_data/`. Copy bit-exact (no whitespace edits). The package's `Package.swift` already pattern-globs `Tests/SheetMusicTests/Resources/**` so no manifest change is needed; verify with `grep -n "Resources" Package.swift`.

- [ ] **Step 1: Locate the upstream fixture**

If the user has a local MuseScore checkout, the files live under
`<musescore-checkout>/src/importexport/midi/tests/midiexport_data/`. Otherwise the user can fetch them from the MuseScore GitHub repository at the same path. Confirm the source path with the user before copying — this is a GPL fixture and the LICENSE entry needs to match the actual upstream location.

- [ ] **Step 2: Copy the two files into the test resources**

```bash
cp <musescore-checkout>/src/importexport/midi/tests/midiexport_data/testSingleNoteDynamics.mscx \
   Tests/SheetMusicTests/Resources/testSingleNoteDynamics.mscx
cp <musescore-checkout>/src/importexport/midi/tests/midiexport_data/testSingleNoteDynamics-ref.mid \
   Tests/SheetMusicTests/Resources/testSingleNoteDynamics-ref.mid
```

- [ ] **Step 3: Update the LICENSE file**

Edit `Tests/SheetMusicTests/Resources/LICENSE`. Append `testSingleNoteDynamics` to the parenthetical list of root fixtures on line 5:

```
  - Root fixtures (midi*, testArpeggio, testVolta*, testSingleNoteDynamics, …):
```

No other LICENSE changes are needed — the upstream path is identical to the existing entries.

- [ ] **Step 4: Verify the resource bundle picks up the new files**

Run: `swift build`
Expected: succeeds, the resource bundle re-generates.

Run a one-off sanity test inline:

```swift
@testable import SheetMusic
import Testing
@Suite struct FixturePresenceTest {
    @Test func testSingleNoteDynamicsBundled() throws {
        let url = Bundle.module.url(forResource: "testSingleNoteDynamics", withExtension: "mscx")
        #expect(url != nil)
    }
}
```

You can drop this into the upcoming `HairpinMidiTests.swift` and remove it once the real fixture-driven test passes. Or skip Step 4 and rely on the next task's failing test to surface a missing-resource error.

- [ ] **Step 5: Commit**

```bash
git add Tests/SheetMusicTests/Resources/testSingleNoteDynamics.mscx \
        Tests/SheetMusicTests/Resources/testSingleNoteDynamics-ref.mid \
        Tests/SheetMusicTests/Resources/LICENSE
git commit -m "test: import testSingleNoteDynamics GPL fixture (test target only)"
```

---

## Task 8: Fixture-driven semantic-equivalence test

**Files:**
- Create: `Tests/SheetMusicTests/HairpinMidiTests.swift`

End-to-end check: parse `testSingleNoteDynamics.mscx`, render to MIDI, compare to `testSingleNoteDynamics-ref.mid` with `ignoreControlChange: true`. This is the spec's headline acceptance test.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/HairpinMidiTests.swift`:

```swift
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct HairpinMidiTests {
    @Test func testSingleNoteDynamicsVelocityRamp() throws {
        let scoreURL = try #require(
            Bundle.module.url(forResource: "testSingleNoteDynamics", withExtension: "mscx")
        )
        let refURL = try #require(
            Bundle.module.url(forResource: "testSingleNoteDynamics-ref", withExtension: "mid")
        )
        let score = try SheetMusic.loadScore(mscxData: Data(contentsOf: scoreURL))
        let produced = try SheetMusic.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)
        try MidiSemanticComparison.assertEquivalent(
            produced: produced,
            reference: reference,
            options: .init(ignoreControlChange: true)
        )
    }
}
```

- [ ] **Step 2: Run the test to see what diverges**

Run: `swift test --filter HairpinMidiTests`
Expected outcomes (rank-ordered by likelihood):

  1. **Pass** — every divergence is CC-only, our ramp matches MuseScore's note-on velocity grid bit-for-bit.
  2. **Off-by-one velocity** at one or two ticks. Inspect the recorded `Issue.record` window. If the difference is consistently ±1, revisit the rounding in `HairpinRamps.interpolate` — MuseScore uses integer truncation in some paths (`engraving/compat/midi/compatmidirender.cpp`), Swift's round-half-away-from-zero may diverge by one. If so, switch to truncation: `let rounded = delta * progress / span`.
  3. **End velocity mismatch** because the bracket-end Dynamic doesn't sit exactly at the hairpin's end tick. Inspect the upstream fixture: if the Dynamic sits at the exact end tick the existing `dynList.first(where: { $0.tick >= p.endTick })` finds it; if it sits slightly before/after, widen to `>= p.endTick - 1` or include the most-recent dynamic before the hairpin start as a fallback.

- [ ] **Step 3: If divergent, narrow the cause and adjust**

If divergent, write the offending tick + produced/reference velocities to a scratch file, then either:

  - Adjust `HairpinRamps.interpolate` rounding (Step 2 case 2).
  - Adjust the end-Dynamic lookup window in `HairpinRamps.collect` (Step 2 case 3).
  - File a follow-up if the divergence is structurally outside the spec's scope (e.g. CC1 modulation differences that survive `ignoreControlChange: true`, which would be a bug in the option).

Re-run `swift test --filter HairpinMidiTests` after each adjustment.

- [ ] **Step 4: Run the full suite to verify the entire pipeline**

Run: `swift test`
Expected: all 48 baseline tests + every test added in Tasks 1-7 + the new fixture test pass. `swift test` reports the same shape as before plus one extra `HairpinMidiTests` case.

- [ ] **Step 5: Commit**

```bash
git add Tests/SheetMusicTests/HairpinMidiTests.swift
git commit -m "test: end-to-end testSingleNoteDynamics velocity ramp"
```

---

## Task 9: Doc + memory updates

**Files:**
- Modify: `/Users/kiichi/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_feature_gaps_checklist.md`

Reflect that hairpin MIDI velocity is no longer a feature gap, and that non-linear curves / Single Note Dynamics CCs are now the named follow-ups.

- [ ] **Step 1: Update the memory entry**

Edit the file. Replace the "hairpin MIDI" bullet with one that says "shipped 2026-MM-DD; follow-ups are non-linear curves, SND CCs, cross-staff Dynamic bracketing, `<TextLine>`-form crescendos". Use today's actual date when committing.

- [ ] **Step 2: Verify the implementation is complete by re-running everything**

Run: `swift test`
Expected: all green, including the new `HairpinMidiTests`.

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings / 0 errors. If the new `renderVoiceElement` parameter count trips a `function_parameter_count` rule, append it to the file's existing `// swiftlint:disable` directive at the top of `MidiRenderer+Voice.swift`.

- [ ] **Step 3: Final commit (memory only — no `git add` for the memory file, it lives outside the repo)**

The memory file is not in this repo; just save it. No `git add` / `git commit` for that part.

---

## Self-Review Notes (results)

**Spec coverage check:**

- Subtype + `<veloChange>` + curve method on `HairpinPayload` → Task 1
- Decoder normalises `0` → `nil` and unknown methods → `.normal` → Task 2
- Encoder omits default-equal tags but always writes `<subtype>` → Task 3
- Hybrid endpoint resolution (bracket Dynamic > `<veloChange>` > ±10) → Task 4 (`collect` resolution loop)
- Linear interpolation only in v1, non-`.normal` falls through → Task 4 (`interpolate`)
- `active` returns latest-starting containing ramp → Task 4
- `MidiRenderer+Voice` chord-onset override; running `velocity` untouched → Task 5
- `originalMeasureBase` / `originalTickDelta` for repeat-aware tick remap → Task 5
- `ignoreControlChange` option, default `false` → Task 6
- GPL fixture import + LICENSE entry → Task 7
- End-to-end `testSingleNoteDynamics` test → Task 8
- Round-trip safety → covered by Task 3's reparse test
- Docs / memory update → Task 9

**Type consistency check:**

- `HairpinRamp` field names (`startTick / endTick / startVelocity / endVelocity / method`) used identically in Tasks 4 and 5.
- `HairpinRamps.collect` signature `(voiceIndex:staff:instrument:division:)` matches between Tasks 4 and 5.
- `Options` struct named `MidiSemanticComparison.Options` in Task 6's overload; the spec used `MidiSemanticComparisonOptions` as a sibling — consolidated to a nested name to keep the helper file self-contained, and consumers reference it via `.init(...)` per the spec snippet, so the call site reads identically.

**Placeholder scan:**

No `TBD`, `TODO`, `implement later`, or "fill in details". Every step has executable code or an explicit inspect-the-output instruction.
