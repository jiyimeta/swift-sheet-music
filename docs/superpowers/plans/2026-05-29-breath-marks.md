# Breath Marks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add MuseScore-faithful breath mark and caesura support (8 SMuFL symbols) end-to-end: Score model, MSCX round-trip, MusicXML import, MIDI playback, Layout (Apple), Android JNI bridge.

**Architecture:** New `Breath` struct in `SheetMusicCore` with a `Kind` enum (`.breathMark(BreathMarkStyle)` / `.caesura(CaesuraStyle)`) and an integer `pause` in seconds. New `VoiceElement.breath(Breath)` case sits as an independent element between two chords — matching MuseScore's segment graph. MIDI playback advances the tick cursor by `pause` seconds; layout emits a SMuFL glyph in the gap before the next chord.

**Tech Stack:** Swift 6, Swift Testing (`@Test`), SwiftPM. Layout via the existing `LayoutEngine` + `FontMetricsProvider` DI seam (CoreText on Apple, Stub on Android). Android JNI bridge via `SheetMusicAndroidJNI`.

**Spec:** `docs/superpowers/specs/2026-05-29-breath-marks-design.md` (commit `ef72bc4`).

**Branch:** `feature/breath-marks` (worktree `.claude/worktrees/breath-marks/`).

---

## Task 1: Score model — `Breath` type + `VoiceElement.breath` case

**Files:**
- Create: `Sources/SheetMusicCore/Score/Breath.swift`
- Modify: `Sources/SheetMusicCore/Score/VoiceElement.swift`
- Test: `Tests/SheetMusicTests/Core/BreathTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/Core/BreathTests.swift`:

```swift
import Testing
@testable import SheetMusicCore

@Suite("Breath")
struct BreathTests {
    @Test("defaultPause returns MuseScore 4 values per kind")
    func defaultPausePerKind() {
        #expect(Breath.defaultPause(for: .breathMark(.comma)) == 0)
        #expect(Breath.defaultPause(for: .breathMark(.tick)) == 0)
        #expect(Breath.defaultPause(for: .breathMark(.upbow)) == 0)
        #expect(Breath.defaultPause(for: .breathMark(.salzedo)) == 0)
        #expect(Breath.defaultPause(for: .caesura(.normal)) == 0.5)
        #expect(Breath.defaultPause(for: .caesura(.short)) == 0.25)
        #expect(Breath.defaultPause(for: .caesura(.thick)) == 0.75)
        #expect(Breath.defaultPause(for: .caesura(.curved)) == 0.5)
    }

    @Test("init applies default pause when pause is nil")
    func initAppliesDefaultPause() {
        let b = Breath(kind: .caesura(.normal))
        #expect(b.pause == 0.5)
    }

    @Test("init accepts explicit pause overriding default")
    func initAcceptsExplicitPause() {
        let b = Breath(kind: .caesura(.normal), pause: 2.0)
        #expect(b.pause == 2.0)
    }

    @Test("visible sugar reflects elementProperties")
    func visibleSugar() {
        var b = Breath(kind: .breathMark(.comma))
        #expect(b.visible == true)
        b.visible = false
        #expect(b.elementProperties.visible == false)
    }

    @Test("VoiceElement.breath constructible and equatable")
    func voiceElementBreath() {
        let a: VoiceElement = .breath(Breath(kind: .breathMark(.tick)))
        let b: VoiceElement = .breath(Breath(kind: .breathMark(.tick)))
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail at compile time**

Run: `swift test --filter BreathTests 2>&1 | head -30`
Expected: build errors — `cannot find 'Breath' in scope`, `type 'VoiceElement' has no member 'breath'`.

- [ ] **Step 3: Create `Sources/SheetMusicCore/Score/Breath.swift`**

```swift
import Foundation

/// A breath mark or caesura sitting between two chords in a voice.
///
/// MuseScore stores both families under one `<Breath>` element
/// distinguished by `<subtype>`. We split them by `Kind` because they
/// differ semantically: breath marks are visual articulations, while
/// caesuras additionally insert a measured silence during playback.
///
/// Position in `Voice.elements`: a `Breath` is an **independent voice
/// element** sitting after the chord it follows — exactly the segment
/// position MuseScore uses. It is not attached to a chord.
///
/// C++: `mu::engraving::Breath`.
public struct Breath: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case breathMark(BreathMarkStyle)
        case caesura(CaesuraStyle)
    }

    public enum BreathMarkStyle: String, Sendable, Equatable, CaseIterable {
        case comma, tick, upbow, salzedo
    }

    public enum CaesuraStyle: String, Sendable, Equatable, CaseIterable {
        case normal, short, thick, curved
    }

    public var kind: Kind

    /// Seconds of silence inserted after the preceding chord during
    /// MIDI playback. Caesura defaults are non-zero (style-dependent);
    /// breath marks default to `0` (visual-only) — matching MuseScore 4
    /// defaults. Mirrors MuseScore `<Breath><pause>`.
    public var pause: Double

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties

    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(kind: Kind, pause: Double? = nil, visible: Bool = true) {
        self.kind = kind
        self.pause = pause ?? Self.defaultPause(for: kind)
        self.elementProperties = ElementProperties(visible: visible)
    }

    /// MuseScore 4 default pause in seconds. Breath marks are
    /// visual-only (0); caesuras insert a style-dependent silence.
    public static func defaultPause(for kind: Kind) -> Double {
        switch kind {
        case .breathMark:
            return 0
        case .caesura(let style):
            switch style {
            case .normal:  return 0.5
            case .short:   return 0.25
            case .thick:   return 0.75
            case .curved:  return 0.5
            }
        }
    }
}
```

- [ ] **Step 4: Add `.breath` case to `VoiceElement`**

Edit `Sources/SheetMusicCore/Score/VoiceElement.swift` — add the new case right after `.fermata(Fermata)`:

```swift
    case fermata(Fermata)
    case breath(Breath)
    case harmony(Harmony)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter BreathTests`
Expected: 5 tests pass. **The wider build will likely now fail** because every exhaustive switch over `VoiceElement` needs a `.breath` arm — that's Task 2.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Score/Breath.swift \
        Sources/SheetMusicCore/Score/VoiceElement.swift \
        Tests/SheetMusicTests/Core/BreathTests.swift
git commit -m "feat(core): add Breath value type and VoiceElement.breath case

Breath is the score-model representation for MuseScore's <Breath>
element, covering both breath marks (comma/tick/upbow/salzedo) and
caesuras (normal/short/thick/curved). Kind enum splits the families;
pause carries the per-element MIDI silence in seconds.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Update every exhaustive `VoiceElement` switch

The compiler enumerates the sites for us. Each arm is added with a clear default behaviour: most consumers ignore `.breath` (not a sounding element, not a tick-bearing chord, not a layout element they care about yet); a few need `tickCount = 0` semantics.

**Approach:** Run `swift build` repeatedly, fixing one compile error at a time. Group the fixes by module so each module's commit history stays clean.

**Files (per build error):** Any of the 30+ files in `Sources/` that switch over `VoiceElement` may flag. Known candidates from the codebase audit:

- `Sources/SheetMusicCore/Editing/DurationChangeAlgorithm.swift`
- `Sources/SheetMusicCore/Editing/PasteVoiceElement.swift`
- `Sources/SheetMusicCore/Editing/PasteVoiceElements.swift`
- `Sources/SheetMusicCore/Editing/RemoveTuplet.swift`
- `Sources/SheetMusicCore/Score/Score+NoteRange.swift`
- `Sources/SheetMusicCore/Score/Score+TieTarget.swift`
- `Sources/SheetMusicCore/Score/ScoreItemID.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Emit.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+YBounds.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Beaming.swift`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Tremolo.swift`
- `Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`
- `Sources/SheetMusicMIDI/Render/FermataRanges.swift`
- `Sources/SheetMusicMIDI/Render/HairpinRamps.swift`
- `Sources/SheetMusicMIDI/Render/OttavaRanges.swift`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Repeats.swift`
- `Sources/SheetMusicMIDI/Import/MidiImporter+Assemble.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice+EncodeChord.swift`
- `Sources/SheetMusicMusicXML/Decoders/MusicXMLGlideTracker.swift`
- `Sources/SheetMusicAndroidJNI/LayoutBridge.swift`

The actual set is whichever ones the compiler reports.

- [ ] **Step 1: Run `swift build` and capture all errors**

Run: `swift build 2>&1 | grep -E "error:|switch must be exhaustive" | head -50`

- [ ] **Step 2: Add `.breath` arms — Core (editing + score) module**

For each compile error in `Sources/SheetMusicCore/`, add a `case .breath:` arm:

- **`DurationChangeAlgorithm.swift`, `PasteVoiceElement.swift`, `PasteVoiceElements.swift`, `RemoveTuplet.swift`**: `.breath` behaves like `.fermata` / `.dynamic` — not a tick-bearing element, never targeted by duration changes. Add `case .breath: …` arm matching whatever the fermata arm does (typically: "skip", "preserve in-place", or "treat as non-temporal").
- **`Score+NoteRange.swift`, `Score+TieTarget.swift`**: breath has no notes. Add `case .breath: return nil` (or the empty-collection equivalent — match what `.fermata` returns).
- **`ScoreItemID.swift`**: if `VoiceElement` participates in stable IDs, add a `.breath` case mirroring `.fermata`'s structure.

Reference the existing `.fermata` arm in each file as the template — breath has the same temporal nullity as fermata.

- [ ] **Step 3: Build & commit Core fixes**

Run: `swift build`
Expected: Core builds cleanly (errors now move to dependent modules).

```bash
git add Sources/SheetMusicCore/
git commit -m "refactor(core): handle VoiceElement.breath in exhaustive switches

Treats breath as a non-tick-bearing, non-note-bearing element parallel
to .fermata across editing algorithms and score queries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Add `.breath` arms — Layout module**

For each compile error in `Sources/SheetMusicLayout/`, add a placeholder `case .breath: break` (or `continue` inside a `for` loop). The real layout work happens in Task 6; for now we only need the switches to compile.

**Exception:** if a function returns a value rather than `Void`, match `.fermata`'s return value (`nil`, `[]`, `0`, …). The pattern to find in each file is whatever neighbouring case `.fermata` does — copy that.

- [ ] **Step 5: Add `.breath` arms — MIDI module**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` around line 341, add a placeholder arm next to `.fermata`:

```swift
case .fermata:
    // Held-duration is realised by per-staff tempo bookends
    // emitted in `MidiRenderer.renderTrack` from
    // `FermataRanges`. The voice walk does not need to
    // touch tempo or tick state here.
    break
case .breath:
    // Implemented in Task 5: advance localTick by the
    // breath's pause-seconds converted to ticks via the
    // current tempo. Placeholder so the switch compiles.
    break
```

In the other MIDI files (`FermataRanges.swift`, `HairpinRamps.swift`, `OttavaRanges.swift`, `MidiRenderer+Repeats.swift`, `MidiImporter+Assemble.swift`), copy the `.fermata` behaviour for `.breath` — typically "skip / not relevant to this pass".

- [ ] **Step 6: Add `.breath` arms — MSCX encoder**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` and `MSCXEncoder+Voice+EncodeChord.swift`, add a placeholder `case .breath: break` arm. Real encoding lives in Task 3.

- [ ] **Step 7: Add `.breath` arms — MusicXML**

In `Sources/SheetMusicMusicXML/Decoders/MusicXMLGlideTracker.swift`, add the `case .breath:` arm that matches `.fermata` (likely a no-op for glide tracking).

- [ ] **Step 8: Add `.breath` arms — Android JNI**

In `Sources/SheetMusicAndroidJNI/LayoutBridge.swift`, add `case .breath: break` (real bridge work in Task 7).

- [ ] **Step 9: Add `.breath` arms — PDF + UI**

In `Sources/SheetMusicPDF/Import/PDFImporter+ScoreState.swift`, `PDFImporter+Voicing.swift`, `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`, `ScoreLayerBuilder+Element.swift`: add placeholder arms matching the `.fermata` case in each file.

- [ ] **Step 10: Verify full build & tests**

Run: `swift build`
Expected: Clean build, no warnings.

Run: `swift test --filter BreathTests`
Expected: 5 pass.

Run: `swift test 2>&1 | tail -5`
Expected: full test suite still green.

- [ ] **Step 11: Commit module-by-module**

```bash
git add Sources/SheetMusicLayout/
git commit -m "refactor(layout): placeholder VoiceElement.breath arms in switches

Real layout emission lands in the breath-layout task. These arms
mirror .fermata's behaviour so the switches compile.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

git add Sources/SheetMusicMIDI/
git commit -m "refactor(midi): placeholder VoiceElement.breath arms in switches

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

git add Sources/SheetMusicMSCX/ Sources/SheetMusicMusicXML/ \
        Sources/SheetMusicAndroidJNI/ Sources/SheetMusicPDF/ Sources/SheetMusicUI/
git commit -m "refactor: placeholder VoiceElement.breath arms across remaining modules

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: MSCX round-trip — decoder + encoder

**Files:**
- Create: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Breath.swift`
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Breath.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- Test: `Tests/SheetMusicTests/MSCX/BreathRoundTripTests.swift`

### SMuFL ↔ Kind mapping table

Used by both decoder and encoder — keep in one place inside `MSCXEncoder+Breath.swift` and re-export to the decoder via an internal helper:

```swift
extension Breath.Kind {
    /// MSCX `<subtype>` ↔ Kind. Returns nil for unknown subtypes
    /// (decoder falls back to `.breathMark(.comma)`).
    static func decode(mscxSubtype: String) -> Breath.Kind? {
        switch mscxSubtype {
        case "breathMarkComma":   return .breathMark(.comma)
        case "breathMarkTick":    return .breathMark(.tick)
        case "breathMarkUpbow":   return .breathMark(.upbow)
        case "breathMarkSalzedo": return .breathMark(.salzedo)
        case "caesura":           return .caesura(.normal)
        case "caesuraShort":      return .caesura(.short)
        case "caesuraThick":      return .caesura(.thick)
        case "caesuraCurved":     return .caesura(.curved)
        default:                  return nil
        }
    }

    /// MSCX `<subtype>` text for round-trip.
    var mscxSubtype: String {
        switch self {
        case .breathMark(.comma):   return "breathMarkComma"
        case .breathMark(.tick):    return "breathMarkTick"
        case .breathMark(.upbow):   return "breathMarkUpbow"
        case .breathMark(.salzedo): return "breathMarkSalzedo"
        case .caesura(.normal):     return "caesura"
        case .caesura(.short):      return "caesuraShort"
        case .caesura(.thick):      return "caesuraThick"
        case .caesura(.curved):     return "caesuraCurved"
        }
    }
}
```

- [ ] **Step 1: Write the failing round-trip test**

Create `Tests/SheetMusicTests/MSCX/BreathRoundTripTests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX

@Suite("Breath MSCX round-trip")
struct BreathRoundTripTests {
    /// Hand-authored MSCX containing one chord + a breath of each kind +
    /// another chord. Wrapped in a minimal Score / Measure / Voice
    /// envelope.
    static func mscxWith(subtype: String, pauseChild: String? = nil) -> String {
        let pauseLine = pauseChild.map { "<pause>\($0)</pause>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                  <Breath><subtype>\(subtype)</subtype>\(pauseLine)</Breath>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>62</pitch><tpc>16</tpc></Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    @Test("decode roundtrips all eight subtypes")
    func decodesAllEightSubtypes() throws {
        let cases: [(subtype: String, expected: Breath.Kind)] = [
            ("breathMarkComma",   .breathMark(.comma)),
            ("breathMarkTick",    .breathMark(.tick)),
            ("breathMarkUpbow",   .breathMark(.upbow)),
            ("breathMarkSalzedo", .breathMark(.salzedo)),
            ("caesura",           .caesura(.normal)),
            ("caesuraShort",      .caesura(.short)),
            ("caesuraThick",      .caesura(.thick)),
            ("caesuraCurved",     .caesura(.curved)),
        ]
        for (subtype, expected) in cases {
            let xml = Self.mscxWith(subtype: subtype)
            let score = try MSCXParser.parse(xmlString: xml)
            let voice = score.staves[0].measures[0].voices[0]
            guard case let .breath(b) = voice.elements[1] else {
                Issue.record("expected .breath at index 1 for \(subtype)")
                continue
            }
            #expect(b.kind == expected)
        }
    }

    @Test("decode applies default pause when <pause> is absent")
    func decodeDefaultPause() throws {
        let xml = Self.mscxWith(subtype: "caesura")
        let score = try MSCXParser.parse(xmlString: xml)
        let voice = score.staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 0.5)
    }

    @Test("decode honours explicit <pause>")
    func decodeExplicitPause() throws {
        let xml = Self.mscxWith(subtype: "caesura", pauseChild: "1.25")
        let score = try MSCXParser.parse(xmlString: xml)
        let voice = score.staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 1.25)
    }

    @Test("unknown subtype falls back to .breathMark(.comma)")
    func unknownSubtypeFallback() throws {
        let xml = Self.mscxWith(subtype: "breathMarkBogusXYZ")
        let score = try MSCXParser.parse(xmlString: xml)
        let voice = score.staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.kind == .breathMark(.comma))
    }

    @Test("encode -> decode round-trip preserves kind and pause")
    func encodeDecodeRoundTrip() throws {
        let originals: [Breath.Kind] = [
            .breathMark(.comma), .breathMark(.tick),
            .breathMark(.upbow), .breathMark(.salzedo),
            .caesura(.normal),   .caesura(.short),
            .caesura(.thick),    .caesura(.curved),
        ]
        for kind in originals {
            let xml = Self.mscxWith(subtype: kind.mscxSubtype, pauseChild: "0.75")
            let parsed = try MSCXParser.parse(xmlString: xml)
            // Re-encode and re-parse.
            let writtenData = try MSCXEncoder.encode(parsed)
            let written = String(data: writtenData, encoding: .utf8)!
            let reparsed = try MSCXParser.parse(xmlString: written)
            let voice = reparsed.staves[0].measures[0].voices[0]
            guard case let .breath(b) = voice.elements[1] else {
                Issue.record("expected .breath after re-parse for \(kind)")
                continue
            }
            #expect(b.kind == kind)
            #expect(b.pause == 0.75)
        }
    }
}
```

- [ ] **Step 2: Confirm tests fail (no decoder yet)**

Run: `swift test --filter BreathRoundTripTests 2>&1 | head -30`
Expected: failures — the parser silently skips `<Breath>` so `voice.elements[1]` is the second chord, not a breath.

- [ ] **Step 3: Create the decoder/encoder mapping helpers**

Create `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Breath.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Breath {
    /// Decode a `<Breath>` element. Unknown `<subtype>` falls back to
    /// `.breathMark(.comma)` with a warning. Missing `<pause>` uses
    /// `Breath.defaultPause(for:)`.
    static func decodeMSCX(_ node: XMLTreeNode) -> Breath {
        let rawSubtype = node.first("subtype")?.text ?? ""
        let kind: Breath.Kind
        if let parsed = Breath.Kind.decode(mscxSubtype: rawSubtype) {
            kind = parsed
        } else {
            mscxDecoderLogger.warning(
                "Unknown <Breath><subtype>: \(rawSubtype, privacy: .public) — falling back to breathMarkComma"
            )
            kind = .breathMark(.comma)
        }
        let pause: Double? = node.first("pause").flatMap { Double($0.text) }
        var b = Breath(kind: kind, pause: pause)
        b.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return b
    }
}
```

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Breath.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Breath.Kind {
    /// MSCX `<subtype>` ↔ Kind. Returns nil for unknown subtypes
    /// (decoder falls back to `.breathMark(.comma)`).
    static func decode(mscxSubtype: String) -> Breath.Kind? {
        switch mscxSubtype {
        case "breathMarkComma":   return .breathMark(.comma)
        case "breathMarkTick":    return .breathMark(.tick)
        case "breathMarkUpbow":   return .breathMark(.upbow)
        case "breathMarkSalzedo": return .breathMark(.salzedo)
        case "caesura":           return .caesura(.normal)
        case "caesuraShort":      return .caesura(.short)
        case "caesuraThick":      return .caesura(.thick)
        case "caesuraCurved":     return .caesura(.curved)
        default:                  return nil
        }
    }

    /// MSCX `<subtype>` text for round-trip.
    var mscxSubtype: String {
        switch self {
        case .breathMark(.comma):   return "breathMarkComma"
        case .breathMark(.tick):    return "breathMarkTick"
        case .breathMark(.upbow):   return "breathMarkUpbow"
        case .breathMark(.salzedo): return "breathMarkSalzedo"
        case .caesura(.normal):     return "caesura"
        case .caesura(.short):      return "caesuraShort"
        case .caesura(.thick):      return "caesuraThick"
        case .caesura(.curved):     return "caesuraCurved"
        }
    }
}

extension Breath {
    /// Build a `<Breath>` element. `<pause>` is omitted when it matches
    /// the kind's default (same "omit defaults" convention used by
    /// Fermata encoding).
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: kind.mscxSubtype),
        ]
        let defaultPause = Breath.defaultPause(for: kind)
        if pause != defaultPause {
            children.append(XMLTreeNode(
                name: "pause",
                text: formatPause(pause),
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Breath", children: children)
    }

    /// Match MuseScore's pause formatting: whole numbers without
    /// trailing `.0`, fractional values verbatim.
    private func formatPause(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}
```

- [ ] **Step 4: Wire the decoder into the voice-element dispatch**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`, add a `"Breath"` case in the same switch that handles `"Fermata"` (around line 211):

```swift
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                let stretch: Double? = child.first("timeStretch").flatMap { Double($0.text) }
                var fermata = Fermata(subtype: subtype, timeStretch: stretch)
                fermata.elementProperties = ElementProperties(decodingMSCXChildrenOf: child)
                appendVoiceElement(.fermata(fermata))
            case "Breath":
                appendVoiceElement(.breath(Breath.decodeMSCX(child)))
```

- [ ] **Step 5: Wire the encoder into the voice-element output**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`, replace the Task 2 placeholder `case .breath: break` with the real emission:

```swift
            case let .breath(breath):
                children.append(breath.encode())
```

(Use the property name the surrounding code uses for the accumulator — likely `children`, `elements`, or similar. Match the `.fermata` arm in the same file.)

- [ ] **Step 6: Run the tests**

Run: `swift test --filter BreathRoundTripTests`
Expected: all 5 tests pass.

- [ ] **Step 7: Run the full test suite to confirm no regressions**

Run: `swift test 2>&1 | tail -10`
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicMSCX/ Tests/SheetMusicTests/MSCX/BreathRoundTripTests.swift
git commit -m "feat(mscx): decode + encode <Breath> for round-trip parity

Eight SMuFL subtypes round-trip through MSCXParser → MSCXWriter →
MSCXParser. Unknown subtypes log a warning and fall back to
breathMarkComma; missing <pause> uses the kind's default.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: MusicXML import

**Files:**
- Create: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Breath.swift`
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift`
- Test: `Tests/SheetMusicTests/MusicXML/BreathImportTests.swift`

In MusicXML, `<breath-mark>` and `<caesura>` live inside `<notations>` of the host `<note>`. Our decoder needs to: extract them, then emit a `VoiceElement.breath(...)` *after* the chord that contains the host note.

- [ ] **Step 1: Inspect the existing notations-parse path**

Run: `grep -n "notations\|breath-mark\|caesura\|articulations" Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift | head -20`

Identify the function/region that consumes `<notations>` children for a note. The new code attaches to that same parsing point.

- [ ] **Step 2: Write the failing import tests**

Create `Tests/SheetMusicTests/MusicXML/BreathImportTests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMusicXML

@Suite("Breath MusicXML import")
struct BreathImportTests {
    static func note(notation: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>480</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <note>
                <pitch><step>C</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
                <notations>\(notation)</notations>
              </note>
              <note>
                <pitch><step>D</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
    }

    @Test("breath-mark values map to BreathMarkStyle")
    func breathMarkValues() throws {
        let cases: [(String, Breath.BreathMarkStyle)] = [
            ("comma", .comma), ("tick", .tick),
            ("upbow", .upbow), ("salzedo", .salzedo),
        ]
        for (value, expected) in cases {
            let xml = Self.note(notation: "<breath-mark>\(value)</breath-mark>")
            let score = try MusicXMLParser.parse(xmlString: xml)
            let voice = score.staves[0].measures[0].voices[0]
            // Expect: chord(C), breath, chord(D)
            guard case let .breath(b) = voice.elements[1] else {
                Issue.record("expected .breath at index 1 for \(value)")
                continue
            }
            #expect(b.kind == .breathMark(expected))
        }
    }

    @Test("caesura values map to CaesuraStyle")
    func caesuraValues() throws {
        let cases: [(String, Breath.CaesuraStyle)] = [
            ("normal", .normal), ("short", .short),
            ("thick", .thick), ("curved", .curved),
        ]
        for (value, expected) in cases {
            let xml = Self.note(notation: "<caesura>\(value)</caesura>")
            let score = try MusicXMLParser.parse(xmlString: xml)
            let voice = score.staves[0].measures[0].voices[0]
            guard case let .breath(b) = voice.elements[1] else {
                Issue.record("expected .breath at index 1 for \(value)")
                continue
            }
            #expect(b.kind == .caesura(expected))
        }
    }

    @Test("empty breath-mark value defaults to comma")
    func emptyBreathMarkDefaultsToComma() throws {
        let xml = Self.note(notation: "<breath-mark/>")
        let score = try MusicXMLParser.parse(xmlString: xml)
        guard case let .breath(b) = score.staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.kind == .breathMark(.comma))
    }

    @Test("empty caesura value defaults to normal")
    func emptyCaesuraDefaultsToNormal() throws {
        let xml = Self.note(notation: "<caesura/>")
        let score = try MusicXMLParser.parse(xmlString: xml)
        guard case let .breath(b) = score.staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.kind == .caesura(.normal))
    }

    @Test("MusicXML import uses default pause (no <pause> in MusicXML)")
    func importUsesDefaultPause() throws {
        let xml = Self.note(notation: "<caesura>thick</caesura>")
        let score = try MusicXMLParser.parse(xmlString: xml)
        guard case let .breath(b) = score.staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 0.75)
    }
}
```

- [ ] **Step 3: Confirm tests fail (no decoder yet)**

Run: `swift test --filter BreathImportTests 2>&1 | head -30`
Expected: failures — voice element at index 1 is the second chord, not a breath.

- [ ] **Step 4: Create the MusicXML decoder helper**

Create `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Breath.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Breath {
    /// Decode a `<breath-mark>` notation child. Empty / unknown values
    /// fall back to `.breathMark(.comma)`.
    static func decodeMusicXMLBreathMark(_ node: XMLTreeNode) -> Breath {
        let style: Breath.BreathMarkStyle
        switch node.text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "comma", "":      style = .comma
        case "tick":           style = .tick
        case "upbow":          style = .upbow
        case "salzedo":        style = .salzedo
        default:               style = .comma
        }
        return Breath(kind: .breathMark(style))
    }

    /// Decode a `<caesura>` notation child. Empty / unknown values
    /// fall back to `.caesura(.normal)`. The MusicXML 3.x form has no
    /// text content; treat that as `normal`.
    static func decodeMusicXMLCaesura(_ node: XMLTreeNode) -> Breath {
        let style: Breath.CaesuraStyle
        switch node.text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "normal", "":     style = .normal
        case "short":          style = .short
        case "thick":          style = .thick
        case "curved":         style = .curved
        default:               style = .normal
        }
        return Breath(kind: .caesura(style))
    }
}
```

- [ ] **Step 5: Wire the decoder into the notations-parse path**

In `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift`, locate the `<notations>` traversal identified in Step 1. After the chord that owns this note has been finalised and appended to `voice.elements`, append a pending `.breath(...)` for each `<breath-mark>` / `<caesura>` child found:

```swift
// Inside the <notations> child loop, alongside fermata / articulation handling:
for child in notationsNode.children {
    switch child.name {
    // ... existing cases ...
    case "breath-mark":
        pendingBreaths.append(Breath.decodeMusicXMLBreathMark(child))
    case "caesura":
        pendingBreaths.append(Breath.decodeMusicXMLCaesura(child))
    default: break
    }
}
// After the chord is appended to voice.elements:
for b in pendingBreaths {
    voiceElements.append(.breath(b))
}
```

Match whatever the surrounding code style is — the variable names above are illustrative. The key constraint: `.breath(...)` must be appended **after** the host chord, in order.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter BreathImportTests`
Expected: all 5 tests pass.

- [ ] **Step 7: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicMusicXML/ Tests/SheetMusicTests/MusicXML/BreathImportTests.swift
git commit -m "feat(musicxml): import <breath-mark> and <caesura> notations

Each notation appends a .breath(...) voice element after its host
chord. Eight value variants map to BreathMarkStyle / CaesuraStyle;
unknown / empty values fall back to comma / normal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: MIDI playback — pause-seconds → tick advance

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`
- Test: `Tests/SheetMusicTests/MIDI/BreathMidiTests.swift`

The render pass walks voice elements per-measure with a running `localTick` cursor. When it hits `.breath(b)` with `b.pause > 0`, advance `localTick` by the tempo-correct tick count. Breath marks with `pause == 0` are a no-op.

### Tick conversion

```
ticks = round(pause * (bpm / 60) * ppq)
      = round(pause * bps * ppq)
```

where `bps = bpm / 60` (beats per second). The renderer already tracks `currentTempoBps` and receives `division` (= ppq) as a parameter.

- [ ] **Step 1: Write the failing MIDI tests**

Create `Tests/SheetMusicTests/MIDI/BreathMidiTests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX

@Suite("Breath MIDI playback")
struct BreathMidiTests {
    /// Build a minimal score: two quarter notes in 4/4 at 120bpm with
    /// a breath of the given kind between them.
    static func score(breathKind: Breath.Kind, pause: Double?) -> Score {
        // Build via MSCXParser to reuse the existing envelope; the
        // round-trip test fixture has the same shape.
        let pauseLine = pause.map { "<pause>\($0)</pause>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Tempo><tempo>2</tempo></Tempo>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                  <Breath><subtype>\(breathKind.mscxSubtype)</subtype>\(pauseLine)</Breath>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        return try! MSCXParser.parse(xmlString: xml)
    }

    @Test("breath mark with pause=0 does not shift the next chord")
    func breathMarkNoShift() throws {
        let s = Self.score(breathKind: .breathMark(.comma), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        let onsets = noteOnTicks(in: midi)
        // Two notes one quarter apart: 0 and 480 ticks at PPQ=480.
        #expect(onsets == [0, 480])
    }

    @Test("caesura with default pause shifts the next chord by pause-seconds")
    func caesuraDefaultPauseShifts() throws {
        // 120 bpm = 2 bps. Caesura .normal pause = 0.5s = 1 beat = 480 ticks at PPQ=480.
        let s = Self.score(breathKind: .caesura(.normal), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        let onsets = noteOnTicks(in: midi)
        #expect(onsets == [0, 480 + 480])  // first chord onset, then quarter + 0.5s pause
    }

    @Test("explicit pause overrides default")
    func explicitPauseOverridesDefault() throws {
        // 0.25s at 120bpm/480ppq = 240 ticks.
        let s = Self.score(breathKind: .breathMark(.comma), pause: 0.25)
        let midi = try MidiRenderer.render(score: s)
        let onsets = noteOnTicks(in: midi)
        #expect(onsets == [0, 480 + 240])
    }

    @Test("preceding chord's note-off is at its natural release (not shortened)")
    func precedingChordNotShortened() throws {
        let s = Self.score(breathKind: .caesura(.normal), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        let firstNoteOff = noteOffTicks(in: midi).first!
        // First note (pitch 60) releases at its natural quarter end = 480.
        #expect(firstNoteOff == 480)
    }

    // Helpers extract sorted noteOn / noteOff ticks for the renderer's
    // first track. Implement using the existing TimedMidiEvent traversal
    // — see MidiSemanticComparison.swift for the pattern.
    private func noteOnTicks(in midi: MidiFile) -> [Int] {
        var result: [Int] = []
        for ev in midi.tracks[0].events {
            if case .noteOn = ev.event { result.append(ev.tick) }
        }
        return result.sorted()
    }
    private func noteOffTicks(in midi: MidiFile) -> [Int] {
        var result: [Int] = []
        for ev in midi.tracks[0].events {
            if case .noteOff = ev.event { result.append(ev.tick) }
        }
        return result.sorted()
    }
}
```

Adjust `MidiRenderer.render(score:)` to whatever the actual public entry point is (likely `MidiRenderer().render(score:)` or a static `MidiFile(from:)`); confirm by `grep -n "func render" Sources/SheetMusicMIDI/Render/MidiRenderer.swift`.

- [ ] **Step 2: Confirm tests fail**

Run: `swift test --filter BreathMidiTests 2>&1 | head -40`
Expected: tests fail — current placeholder ignores the breath, so the caesura case shows onsets `[0, 480]` instead of `[0, 960]`.

- [ ] **Step 3: Replace the placeholder breath arm in `MidiRenderer+Voice.swift`**

Around line 341, replace the placeholder:

```swift
        case .breath:
            // Implemented in Task 5: …
            break
```

with the real implementation:

```swift
        case let .breath(breath):
            // Advance localTick by the breath's pause-seconds, converted
            // via the active tempo: ticks = pause * bps * ppq. A pause of
            // zero (breath marks default) is a no-op. The preceding
            // chord's note-off events stay at their natural release —
            // MuseScore inserts dead time rather than shortening the chord.
            if breath.pause > 0 {
                let extraTicks = Int((breath.pause * currentTempoBps * Double(division)).rounded())
                localTick += extraTicks
            }
```

(`currentTempoBps` and `division` are already in scope in this function; confirm by looking at the surrounding `case .chord` arm.)

- [ ] **Step 4: Run the MIDI tests**

Run: `swift test --filter BreathMidiTests`
Expected: 4 tests pass.

- [ ] **Step 5: Verify no regressions in the MuseScore equivalence harness**

Run: `swift test --filter MidiExportTests`
Expected: 12 cases still green.

Run: `swift test 2>&1 | tail -10`
Expected: full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift \
        Tests/SheetMusicTests/MIDI/BreathMidiTests.swift
git commit -m "feat(midi): caesura inserts pause-seconds of silence; breath marks no-op

Advances the voice walker's localTick by pause * bps * ppq when the
breath's pause is non-zero. Matches MuseScore 4 Breath::play() —
the previous chord's note-off stays at its natural release; dead
time is inserted, not subtracted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Layout — glyph, placement, horizontal spacing, snapshot

**Files:**
- Create: `Sources/SheetMusicLayout/Engraving/BreathGlyph.swift`
- Create: `Sources/SheetMusicLayout/Fonts/BreathGlyphMetrics.swift`
- Modify: `Sources/SheetMusicLayout/Engraving/SMuFLCodepoints.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift` (add `.breath` case)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Emit.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+YBounds.swift`
- Test: `Tests/SheetMusicTests/Layout/BreathLayoutTests.swift`

### SMuFL codepoints

| Kind                          | Codepoint |
| ----------------------------- | --------- |
| `breathMark(.comma)`          | `U+E4CE`  |
| `breathMark(.tick)`           | `U+E4CF`  |
| `breathMark(.upbow)`          | `U+E4D0`  |
| `breathMark(.salzedo)`        | `U+E4D5`  |
| `caesura(.normal)`            | `U+E4D1`  |
| `caesura(.short)`             | `U+E4D3`  |
| `caesura(.thick)`             | `U+E4D2`  |
| `caesura(.curved)`            | `U+E4D4`  |

### Placement constants (initial values; tune against snapshot)

- Breath mark Y: `topStaffLineY - 1.0 * spatium`
- Caesura Y: `topStaffLineY - 2.0 * spatium`
- Horizontal gap reserved before next chord: `1.0 * spatium` (breath mark), `1.5 * spatium` (caesura — wider)
- Right-padding after glyph: `0.5 * spatium`

- [ ] **Step 1: Map kinds to codepoints**

Create `Sources/SheetMusicLayout/Engraving/BreathGlyph.swift`:

```swift
import Foundation
import SheetMusicCore

/// SMuFL codepoint + Y-offset rule for one breath/caesura kind.
public struct BreathGlyph: Sendable, Equatable {
    public let codepoint: UInt32
    /// Y offset above the top staff line, in spatium units (positive
    /// = further above the staff).
    public let yAboveTopLineSpatia: Double
    /// Horizontal gap to reserve before the next chord, in spatium.
    public let gapBeforeNextChordSpatia: Double

    public static func glyph(for kind: Breath.Kind) -> BreathGlyph {
        switch kind {
        case .breathMark(.comma):
            return BreathGlyph(codepoint: 0xE4CE, yAboveTopLineSpatia: 1.0, gapBeforeNextChordSpatia: 1.0)
        case .breathMark(.tick):
            return BreathGlyph(codepoint: 0xE4CF, yAboveTopLineSpatia: 1.0, gapBeforeNextChordSpatia: 1.0)
        case .breathMark(.upbow):
            return BreathGlyph(codepoint: 0xE4D0, yAboveTopLineSpatia: 1.5, gapBeforeNextChordSpatia: 1.0)
        case .breathMark(.salzedo):
            return BreathGlyph(codepoint: 0xE4D5, yAboveTopLineSpatia: 1.0, gapBeforeNextChordSpatia: 1.0)
        case .caesura(.normal):
            return BreathGlyph(codepoint: 0xE4D1, yAboveTopLineSpatia: 2.0, gapBeforeNextChordSpatia: 1.5)
        case .caesura(.short):
            return BreathGlyph(codepoint: 0xE4D3, yAboveTopLineSpatia: 2.0, gapBeforeNextChordSpatia: 1.5)
        case .caesura(.thick):
            return BreathGlyph(codepoint: 0xE4D2, yAboveTopLineSpatia: 2.0, gapBeforeNextChordSpatia: 1.5)
        case .caesura(.curved):
            return BreathGlyph(codepoint: 0xE4D4, yAboveTopLineSpatia: 2.0, gapBeforeNextChordSpatia: 1.5)
        }
    }
}
```

- [ ] **Step 2: Add codepoints to `SMuFLCodepoints.swift`**

If `SMuFLCodepoints.swift` has named constants for engraving lookups (see how `fermataAbove` is declared there for the pattern), add:

```swift
public static let breathMarkComma: UInt32   = 0xE4CE
public static let breathMarkTick: UInt32    = 0xE4CF
public static let breathMarkUpbow: UInt32   = 0xE4D0
public static let breathMarkSalzedo: UInt32 = 0xE4D5
public static let caesura: UInt32           = 0xE4D1
public static let caesuraShort: UInt32      = 0xE4D3
public static let caesuraThick: UInt32      = 0xE4D2
public static let caesuraCurved: UInt32     = 0xE4D4
```

Inspect the existing file first to match its conventions exactly (some codebases prefer `Character` constants over `UInt32`).

- [ ] **Step 3: Add glyph metrics provider**

Create `Sources/SheetMusicLayout/Fonts/BreathGlyphMetrics.swift`, modelled on `FermataGlyphMetrics.swift`:

```swift
import Foundation
import SheetMusicCore

/// Looks up advance / bounding-box metrics for a breath/caesura glyph
/// through the layout's `FontMetricsProvider`. Apple builds plug in
/// `SheetMusicLayoutApple`'s CoreText provider; Android falls back to
/// the stub provider with rectangle approximations.
public enum BreathGlyphMetrics {
    /// Horizontal advance for the breath glyph at the given spatium,
    /// in points.
    public static func advance(
        for kind: Breath.Kind,
        spatium: Double,
        provider: any FontMetricsProvider,
    ) -> Double {
        let cp = BreathGlyph.glyph(for: kind).codepoint
        return provider.advance(forGlyph: cp, fontSizeUPM: spatium * 4)
    }
}
```

(Confirm the exact `FontMetricsProvider` API surface by reading `FermataGlyphMetrics.swift` — copy that shape.)

- [ ] **Step 4: Add the `LayoutElement.breath` case**

In `Sources/SheetMusicLayout/Layout/LayoutElement.swift`, add a `.breath` case carrying the placement:

```swift
case breath(LayoutBreath)
```

And define `LayoutBreath` in the same file (or a sibling file matching the surrounding pattern):

```swift
public struct LayoutBreath: Sendable, Equatable {
    public var kind: Breath.Kind
    /// Resolved X position in spatium-coords from the system's left edge.
    public var x: Double
    /// Resolved Y position in spatium-coords from the staff's top line.
    public var y: Double
    /// Used by the invisible-element overlay path.
    public var visible: Bool
}
```

- [ ] **Step 5: Translate `VoiceElement.breath` → `LayoutElement.breath`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`, replace the Task 2 placeholder `case .breath: break` arm with the real translation. Match how `.fermata` is translated nearby — at this stage we only construct the element with a placeholder `x = 0`; final X is resolved in spacing.

```swift
case let .breath(breath):
    let glyph = BreathGlyph.glyph(for: breath.kind)
    out.append(.breath(LayoutBreath(
        kind: breath.kind,
        x: 0,  // resolved in LayoutEngine+Spacing
        y: -glyph.yAboveTopLineSpatia,  // negative = above top line in this coord system
        visible: breath.visible,
    )))
```

(Match the actual sign convention used elsewhere — `.fermata` placement is the authority.)

- [ ] **Step 6: Reserve horizontal space**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`, replace the Task 2 placeholder. Where `.fermata` or `.dynamic` arms inject horizontal padding, add a `.breath` arm that:

1. Reads `BreathGlyph.glyph(for: kind).gapBeforeNextChordSpatia`.
2. Reserves that much horizontal room *before* the next chord.
3. Places the breath glyph centred (or left-biased per MuseScore: glyph anchor sits in the gap, near the next chord's left edge minus the advance).

Pseudo-shape (real call sites vary — model on `.fermata`'s spacing arm):

```swift
case let .breath(breathEl):
    let gap = BreathGlyph.glyph(for: breathEl.kind).gapBeforeNextChordSpatia
    let advance = BreathGlyphMetrics.advance(
        for: breathEl.kind, spatium: spatium, provider: fontProvider,
    )
    // Reserve gap*spatium before the next chord; place glyph at
    // (next-chord-left - gap*spatium + (gap*spatium - advance)/2).
    cursorX += gap * spatium
    breathEl.x = cursorX - gap * spatium / 2 - advance / 2
```

- [ ] **Step 7: Emit the glyph**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Emit.swift`, add a `.breath` arm that builds a glyph draw element from `LayoutBreath.codepoint`, position, and `visible`. Model on the `.fermata` emit path.

- [ ] **Step 8: Y-bounds**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+YBounds.swift`, add a `.breath` arm that contributes the breath's Y extent to the system's vertical extent calculation. Use `BreathGlyph.glyph(for:).yAboveTopLineSpatia` plus the glyph's ascender from `BreathGlyphMetrics` to compute the top.

- [ ] **Step 9: Write the layout assertion test**

Create `Tests/SheetMusicTests/Layout/BreathLayoutTests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicLayoutApple
@testable import SheetMusicMSCX

@Suite("Breath layout")
struct BreathLayoutTests {
    @Test("breath produces a LayoutElement.breath between the two chords")
    func breathElementEmitted() throws {
        // Reuse the round-trip fixture XML.
        let xml = BreathRoundTripTests.mscxWith(subtype: "breathMarkComma")
        let score = try MSCXParser.parse(xmlString: xml)
        let doc = LayoutEngine.layout(score: score, fontProvider: CoreTextFontMetricsProvider())
        let staff = doc.systems[0].staves[0]
        // Find the breath element among the staff's elements.
        let breaths = staff.elements.compactMap {
            if case let .breath(b) = $0 { return b }
            return nil
        }
        #expect(breaths.count == 1)
        #expect(breaths.first?.kind == .breathMark(.comma))
    }

    @Test("caesura reserves more horizontal space than a breath mark")
    func caesuraIsWiderThanBreathMark() throws {
        // Compare overall system width: the caesura case must be at
        // least 0.5 spatium wider than the breath-mark case (1.5sp vs
        // 1.0sp gap).
        let provider = CoreTextFontMetricsProvider()
        let breathXml = BreathRoundTripTests.mscxWith(subtype: "breathMarkComma")
        let caesuraXml = BreathRoundTripTests.mscxWith(subtype: "caesura")
        let breathDoc = LayoutEngine.layout(score: try MSCXParser.parse(xmlString: breathXml), fontProvider: provider)
        let caesuraDoc = LayoutEngine.layout(score: try MSCXParser.parse(xmlString: caesuraXml), fontProvider: provider)
        // Whatever the system-width accessor is — `systems[0].width`,
        // `bounds.width`, etc. — confirm by reading LayoutDocument.swift.
        #expect(caesuraDoc.systems[0].width > breathDoc.systems[0].width)
    }
}
```

**Note for the executor:** The exact `LayoutEngine.layout(score:fontProvider:)` entry point and `LayoutDocument` accessors (`.systems[0].width`, `.staves[0].elements`) must be confirmed against the codebase before running this test. Run `grep -rn "public " Sources/SheetMusicLayout/Layout/LayoutDocument.swift Sources/SheetMusicLayout/Layout/LayoutEngine.swift | head -30` and adapt the test to whatever the real API is. If `systems[0].width` doesn't exist, walk the staff elements and find the rightmost X.

- [ ] **Step 10: Run the layout tests**

Run: `swift test --filter BreathLayoutTests`
Expected: both tests pass.

- [ ] **Step 11: Snapshot via `RenderPreviews`**

Add or modify a `#Preview` block in `Sources/RenderPreviews/main.swift` that loads the breath fixture and renders one page. Then:

```bash
swift run RenderPreviews --preview breath-marks --output /tmp/breath-marks.png
```

(Match whatever the existing `RenderPreviews` CLI shape is — `grep -n "CommandLine\|argv" Sources/RenderPreviews/main.swift`.)

Visually inspect `/tmp/breath-marks.png` — confirm:
- A comma glyph appears above the staff between the two chords.
- The two chords are visually separated by ~1 spatium of extra gap.
- The glyph sits near (but not touching) the next chord.

Tune `BreathGlyph` Y / gap constants if the snapshot is off. Re-run RenderPreviews and re-inspect. No commit until visually acceptable.

- [ ] **Step 12: Full test suite + commit**

Run: `swift test 2>&1 | tail -10`
Expected: green.

```bash
git add Sources/SheetMusicLayout/ \
        Tests/SheetMusicTests/Layout/BreathLayoutTests.swift \
        Sources/RenderPreviews/main.swift
git commit -m "feat(layout): emit breath/caesura SMuFL glyphs with horizontal reservation

Eight glyph codepoints map via BreathGlyph; LayoutEngine+Spacing
reserves 1.0sp (breath) or 1.5sp (caesura) before the next chord;
LayoutEngine+Emit places the glyph above the top staff line.
BreathGlyphMetrics looks up advance through the FontMetricsProvider
DI seam so Apple gets CoreText metrics and Android gets stub
rectangles.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Android JNI bridge

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift`
- Test: `Tests/SheetMusicTests/Android/BreathJNITests.swift` (wrapped in `#if !os(Android)` only if it imports Apple frameworks — the JNI tests are Foundation-only and run on both hosts)

The Android side already ships Bravura's SMuFL font, so the eight codepoints are present in the existing glyph table. No new `FontID` is needed — the existing `.smufl` route works.

- [ ] **Step 1: Locate the engraving-element bridge**

Run: `grep -n "LayoutElement\|fermata\|case .fermata\|DrawCommand.glyph" Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift | head -20`

Identify where `.fermata` is translated into a `DrawCommand.glyph`. The new arm sits next to it.

- [ ] **Step 2: Add the `.breath` arm**

In `Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift`, replace the Task 2 placeholder with:

```swift
case let .breath(b):
    let cp = BreathGlyph.glyph(for: b.kind).codepoint
    out.append(.glyph(GlyphDrawCommand(
        font: .smufl,
        codepoint: cp,
        x: b.x,  // already in mm or whatever unit the bridge expects
        y: b.y,
        sizeMM: spatiumMM * 4,
    )))
```

(Match the actual `DrawCommand.glyph` shape and unit conventions used by neighbouring arms.)

- [ ] **Step 3: Write a JNI-side test**

Create `Tests/SheetMusicTests/Android/BreathJNITests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicAndroidJNI

@Suite("Breath JNI bridge")
struct BreathJNITests {
    @Test("breath emits exactly one glyph DrawCommand with the right codepoint")
    func breathEmitsGlyphCommand() throws {
        let xml = BreathRoundTripTests.mscxWith(subtype: "caesura")
        let score = try MSCXParser.parse(xmlString: xml)
        let layout = LayoutEngine.layout(score: score, fontProvider: StubFontMetricsProvider())
        let commands = LayoutBridge.buildCommands(layout: layout)
        let glyphs = commands.compactMap { cmd -> UInt32? in
            if case let .glyph(g) = cmd, g.codepoint == 0xE4D1 { return g.codepoint }
            return nil
        }
        #expect(glyphs.count == 1)
    }
}
```

- [ ] **Step 4: Run the JNI test**

Run: `swift test --filter BreathJNITests`
Expected: pass.

- [ ] **Step 5: Android cross-compile sanity check**

If the host has the Swift Android SDK installed (see CLAUDE.md "Android build" section), run:

```bash
export TOOLCHAINS=org.swift.632202605101a
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: clean cross-compile. If the SDK is not installed, skip this step and rely on the next CI run to flag any Android-side issue.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift \
        Tests/SheetMusicTests/Android/BreathJNITests.swift
git commit -m "feat(android): emit DrawCommand.glyph for LayoutElement.breath

Eight SMuFL codepoints route through the existing Bravura font; no
new FontID needed. Wire format version stays at v4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Step 1: Full Apple test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all green.

- [ ] **Step 2: SwiftLint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings / 0 errors.

- [ ] **Step 3: Example Mac app — visual smoke test**

Open `Examples/Apple/SheetMusicExample.xcodeproj` (regenerate via `cd Examples/Apple && xcodegen` first if needed). Build and run the Mac scheme. Load any `.mscx` containing a breath or caesura (the round-trip fixture works fine — paste it into a temp file). Confirm the glyph renders between the two chords.

- [ ] **Step 4: Update CLAUDE.md if any new conventions emerged**

If the implementation introduced a new pattern (e.g. a new `FontMetricsProvider` method, a new shared SMuFL helper), document it in `docs/musescore-engraving-reference.md` or the file's own header doc.

- [ ] **Step 5: Push branch + open PR**

(Only when the user authorises this — per session rules, don't push without explicit consent.)

```bash
git push -u origin feature/breath-marks
gh pr create --title "feat: breath marks and caesuras" --body "$(cat docs/superpowers/specs/2026-05-29-breath-marks-design.md | head -50)

…

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
