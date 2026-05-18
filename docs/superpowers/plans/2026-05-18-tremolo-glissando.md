# Tremolo + MusicXML Glissando + Diatonic Key Signature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three notation gaps from the post-articulations audit — implement tremolo end-to-end (model → MSCX → MIDI → layout → UI), add MusicXML `<glissando>` / `<slide>` import, and make `.diatonic` glissando use the active key signature's PC set via a `KeySignature.diatonicPitchClasses` helper.

**Architecture:** Three independent phases share no state. Phase 1 adds a `Tremolo` value to `Chord`, with pair-resolution done in-place by each consumer (decoder second pass, MIDI voice walk, layout placement) — no back-pointers. Phase 2 reuses the existing `Glissando` model; pairing is per-part scoped via a `<glissando>/<slide>` pending-dict in the MusicXML note decoder. Phase 3 promotes the existing `majorScalePCs(forKeySignature:)` helper out of `MidiRenderer+GlissandoMath.swift` onto `KeySignature` (using the spec's circle-of-fifths derivation) so the math layer takes a `Set<Int>` parameter and the renderer resolves it from `KeySignature`.

**Tech Stack:** Swift Package Manager, Swift Testing (`@Test`, `#expect`), `Foundation.XMLParser` via `SheetMusicXMLTools`, AVFoundation-adjacent MIDI render, SwiftUI (`Path`) for UI. Layout target: macOS 15 / iOS 17.

**Spec:** `docs/superpowers/specs/2026-05-18-tremolo-glissando-design.md`

---

## File Structure

### Phase 1 — Tremolo

- **Create** `Sources/SheetMusicCore/Score/Tremolo.swift` — `Tremolo` struct with `Subtype` / `Span` / `StrokeStyle` enums.
- **Modify** `Sources/SheetMusicCore/Score/Chord.swift` — add `tremolo: Tremolo?` field + initializer parameter.
- **Modify** `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` — parse `<Tremolo>` child element into `Tremolo` (subtype + stroke style only; span stays `.single` until second pass).
- **Modify** `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` (or `MSCXDecoder+Measure.swift`, whichever owns post-chord wiring) — add a second pass over each decoded voice that promotes `c*`-subtype tremolos to `.between` and clears the duplicate on the follower chord.
- **Modify** `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` — emit `<Tremolo>` block; for `.between`, also emit on the follower chord during voice encoding.
- **Modify** `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` — when encoding the follower chord of a `.between` tremolo, pass a flag to re-emit the same `<Tremolo>` block.
- **Create** `Sources/SheetMusicMIDI/Render/MidiRenderer+Tremolo.swift` — `tremoloSegments(...)` helper returning `[TremoloSegment]`, internal `TremoloSegment` struct.
- **Modify** `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — in the `.chord` branch of `renderVoiceElement`, when `chord.tremolo != nil`, fork to a tremolo emission path that resolves the follower chord, walks segments, and marks the follower index as consumed via a `consumedChordIndices: Set<Int>` accumulator carried through the voice walk.
- **Modify** `Sources/SheetMusicLayout/Layout/LayoutElement.swift` — add `case tremoloBars(anchor: TremoloAnchor, barCount: Int)` and a `TremoloAnchor` enum with `.single(stemSegment:)` / `.between(leftStem:rightStem:)` variants (use existing layout reference types for the segment refs — see `EventColumn` / `LayoutMeasure` for the chord-segment ID scheme).
- **Modify** `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — after stem finalization, emit `.tremoloBars` for any chord with `tremolo != nil`.
- **Create** `Sources/SheetMusicUI/Rendering/TremoloRenderer.swift` — draws bars as slanted SwiftUI `Path` rectangles; bar count from element, slant fixed at +12°, thickness from `metrics.beamThickness`.
- **Modify** `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` — dispatch `.tremoloBars` to `TremoloRenderer`.
- **Create** `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`
- **Create** `Tests/SheetMusicTests/TremoloMSCXEncodeTests.swift`
- **Create** `Tests/SheetMusicTests/TremoloMIDIRenderTests.swift`
- **Create** `Tests/SheetMusicTests/TremoloLayoutTests.swift`

### Phase 2 — MusicXML glissando / slide import

- **Modify** `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder.swift` — add a `pendingGlides: [GlideKey: PendingGlide]` dictionary scoped to a single `<part>` decode session; clear at part boundary.
- **Modify** `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift` — inside the `<notations>` walk, parse `<glissando>` / `<slide>`, registering starts and finalizing stops against the pending dict.
- **Modify** `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Part.swift` (if it exists; otherwise the part-walking entry point) — clear `pendingGlides` at `</part>`.
- **Create** `Tests/SheetMusicTests/Resources/glissando-wavy.musicxml`
- **Create** `Tests/SheetMusicTests/Resources/slide-portamento.musicxml`
- **Create** `Tests/SheetMusicTests/Resources/glissando-unmatched-stop.musicxml`
- **Create** `Tests/SheetMusicTests/MusicXMLGlissandoTests.swift`

### Phase 3 — Diatonic glissando key signature awareness

- **Modify** `Sources/SheetMusicCore/Score/KeySignature.swift` — add `public var diatonicPitchClasses: Set<Int>` via the circle-of-fifths algorithm; result must match the spec's 15-row table.
- **Modify** `Sources/SheetMusicMIDI/Render/MidiRenderer+GlissandoMath.swift` — replace `majorScalePCs(forKeySignature:)` callsite in the `.diatonic` branch with a `KeySignature(concertKey:).diatonicPitchClasses` resolution; remove the now-unused `majorScalePCs` helper; update the `glissando.cpp:222` comment to reflect "key-signature-derived PC set" semantics and note the Tab / non-five-line-staff divergence.
- **Create** `Tests/SheetMusicTests/DiatonicPitchClassesTests.swift` — verify the 15 entries in the spec table.
- **Create** `Tests/SheetMusicTests/GlissandoDiatonicKeyTests.swift` — verify renderer behaviour in G major (F♯ not F), F minor (Ab / Bb / Db / Eb), and C major (E not Eb).

---

## Phase 1 — Tremolo

### Task 1.1: `Tremolo` value type

**Files:**
- Create: `Sources/SheetMusicCore/Score/Tremolo.swift`
- Test: `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift` (skeleton only; full tests come in Task 1.3)

- [ ] **Step 1: Write the failing model test**

Create `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

struct TremoloModelTests {
    @Test func tremolo_default_init() {
        let t = Tremolo(subtype: .r16)
        #expect(t.subtype == .r16)
        #expect(t.span == .single)
        #expect(t.strokeStyle == .default)
    }

    @Test func tremolo_full_init() {
        let t = Tremolo(subtype: .r8, span: .between, strokeStyle: .traditional)
        #expect(t.subtype == .r8)
        #expect(t.span == .between)
        #expect(t.strokeStyle == .traditional)
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `swift test --filter TremoloModelTests`
Expected: FAIL with `cannot find 'Tremolo' in scope`.

- [ ] **Step 3: Create the type**

Create `Sources/SheetMusicCore/Score/Tremolo.swift`:

```swift
import Foundation

/// Beamed-stem tremolo notation. Attached to a `Chord`; for two-note
/// tremolo, the value is held by the *first* chord of the pair and the
/// second chord is named by adjacency in the voice's element list.
///
/// C++: `mu::engraving::TremoloSingleChord` / `TremoloTwoChord`.
public struct Tremolo: Sendable, Hashable {
    /// Number of tremolo bars. Maps to MuseScore subtype tokens:
    /// `r8`/`c8` = 1 (eighth bar), `r16`/`c16` = 2, `r32`/`c32` = 3.
    public enum Subtype: UInt8, Sendable, Hashable {
        case r8 = 1
        case r16 = 2
        case r32 = 3
    }

    /// `.single`: bars cross the chord's own stem.
    /// `.between`: bars sit between this chord and the next chord in
    /// the same voice. The pair partner is *not* stored as a back-
    /// reference — it is looked up by walking the voice's element list.
    /// Inserting a chord between the start and original follower
    /// silently re-pairs to the new neighbor, matching MuseScore's
    /// editor convention.
    public enum Span: Sendable, Hashable {
        case single
        case between
    }

    /// Stem-stroke variant. v1 MIDI rendering treats `.z` as
    /// `.traditional`. C++: `TremoloStyle`.
    public enum StrokeStyle: String, Sendable, Hashable {
        case `default`
        case traditional
        case z
    }

    public var subtype: Subtype
    public var span: Span
    public var strokeStyle: StrokeStyle

    public init(
        subtype: Subtype,
        span: Span = .single,
        strokeStyle: StrokeStyle = .default,
    ) {
        self.subtype = subtype
        self.span = span
        self.strokeStyle = strokeStyle
    }
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `swift test --filter TremoloModelTests`
Expected: PASS.

- [ ] **Step 5: Add `tremolo: Tremolo?` to `Chord`**

Edit `Sources/SheetMusicCore/Score/Chord.swift`:

```swift
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: ChordNotes
    public var arpeggio: Arpeggio?
    public var lyrics: [Lyric]
    public var graceNotesBefore: [GraceChord]
    public var graceNotesAfter: [GraceChord]
    public var articulations: [ChordArticulation]
    /// Tremolo notation attached to this chord. For two-note tremolo
    /// (`.between`), this value is held by the *start* chord of the
    /// pair; the follower is identified by adjacency in the voice's
    /// element list.
    public var tremolo: Tremolo?

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = [],
        graceNotesBefore: [GraceChord] = [],
        graceNotesAfter: [GraceChord] = [],
        articulations: [ChordArticulation] = [],
        tremolo: Tremolo? = nil,
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
        self.graceNotesBefore = graceNotesBefore
        self.graceNotesAfter = graceNotesAfter
        self.articulations = articulations
        self.tremolo = tremolo
    }
}
```

- [ ] **Step 6: Build whole package**

Run: `swift build`
Expected: succeeds (existing call sites of `Chord.init` keep working because `tremolo` defaults to `nil`).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicCore/Score/Tremolo.swift Sources/SheetMusicCore/Score/Chord.swift Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift
git commit -m "core: introduce Tremolo value type and Chord.tremolo field"
```

---

### Task 1.2: MSCX decoder reads `<Tremolo>` (first pass, single-chord)

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`
- Test: `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`

- [ ] **Step 1: Write failing decode tests**

Append to `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`:

```swift
import SheetMusicXMLTools
@testable import SheetMusicMSCX

struct TremoloMSCXDecodeFirstPassTests {
    @Test func decodes_r16_as_single() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r16</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        let chord = try Chord.decode(node)
        #expect(chord.tremolo?.subtype == .r16)
        #expect(chord.tremolo?.span == .single)
        #expect(chord.tremolo?.strokeStyle == .default)
    }

    @Test func decodes_c8_as_single_before_pairing_pass() throws {
        // The first-pass result of a two-note tremolo: span is .single;
        // promotion to .between happens in MSCXDecoder+Voice's second pass.
        let xml = """
        <Chord>
            <durationType>half</durationType>
            <Tremolo>
                <subtype>c8</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        let chord = try Chord.decode(node)
        #expect(chord.tremolo?.subtype == .r8)
        // First-pass span is .between to signal "I am a two-chord start";
        // the second pass verifies the follower exists.
        #expect(chord.tremolo?.span == .between)
    }

    @Test func decodes_strokeStyle_traditional() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r8</subtype>
                <strokeStyle>1</strokeStyle>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        let chord = try Chord.decode(node)
        #expect(chord.tremolo?.strokeStyle == .traditional)
    }

    @Test func unknown_subtype_throws() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r64</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        #expect(throws: SheetMusicError.self) {
            _ = try Chord.decode(node)
        }
    }
}
```

(Note: `XMLTreeNode.parse(xml:)` may not exist verbatim — verify the test helper name in `Tests/SheetMusicTests/Helpers/` and adapt. Existing MSCX decode tests are the reference for the right call.)

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter TremoloMSCXDecodeFirstPassTests`
Expected: FAIL (`tremolo` is nil on every decoded chord).

- [ ] **Step 3: Implement the `<Tremolo>` parser**

Edit `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`. After the `articulations` line and before the `return Chord(...)`, add:

```swift
        var tremolo: Tremolo?
        if let tremoloNode = node.first("Tremolo") {
            guard let subtypeText = tremoloNode.first("subtype")?.text else {
                throw SheetMusicError.malformedScore(
                    reason: "Tremolo missing <subtype>",
                )
            }
            let (parsedSubtype, parsedSpan): (Tremolo.Subtype, Tremolo.Span)
            switch subtypeText {
            case "r8":  (parsedSubtype, parsedSpan) = (.r8,  .single)
            case "r16": (parsedSubtype, parsedSpan) = (.r16, .single)
            case "r32": (parsedSubtype, parsedSpan) = (.r32, .single)
            case "c8":  (parsedSubtype, parsedSpan) = (.r8,  .between)
            case "c16": (parsedSubtype, parsedSpan) = (.r16, .between)
            case "c32": (parsedSubtype, parsedSpan) = (.r32, .between)
            default:
                throw SheetMusicError.malformedScore(
                    reason: "Tremolo unknown <subtype> \(subtypeText)",
                )
            }
            let strokeText = tremoloNode.first("strokeStyle")?.text ?? "0"
            let stroke: Tremolo.StrokeStyle
            switch strokeText {
            case "1": stroke = .traditional
            case "2": stroke = .z
            default:  stroke = .default
            }
            tremolo = Tremolo(
                subtype: parsedSubtype,
                span: parsedSpan,
                strokeStyle: stroke,
            )
        }
```

Then pass `tremolo: tremolo` into the `Chord(...)` initializer call.

- [ ] **Step 4: Run, verify passes**

Run: `swift test --filter TremoloMSCXDecodeFirstPassTests`
Expected: all 4 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift
git commit -m "mscx: decode <Tremolo> subtype + strokeStyle into Chord.tremolo"
```

---

### Task 1.3: MSCX decoder second pass — validate / clean two-chord pairs

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`
- Test: `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`

- [ ] **Step 1: Read `MSCXDecoder+Voice.swift` to locate the post-decode hook**

Run: `grep -n "func decode\|return Voice\|\.chord(" Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`

Identify the point where the `elements: [VoiceElement]` array is fully built and `Voice(...)` is about to be returned. The second pass mutates that array in place.

- [ ] **Step 2: Write failing pairing test**

Append to `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`:

```swift
@testable import SheetMusicMSCX

struct TremoloMSCXDecodeSecondPassTests {
    @Test func c8_pair_clears_follower_tremolo() throws {
        // Two half-notes both marked c8 — the start keeps .between,
        // the follower has its redundant tremolo cleared.
        let xml = """
        <voice>
            <Chord>
                <durationType>half</durationType>
                <Tremolo><subtype>c8</subtype></Tremolo>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
            </Chord>
            <Chord>
                <durationType>half</durationType>
                <Tremolo><subtype>c8</subtype></Tremolo>
                <Note><pitch>64</pitch><tpc>18</tpc></Note>
            </Chord>
        </voice>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        let voice = try Voice.decode(node, measureDuration: Fraction(4, 4))
        guard case let .chord(c0) = voice.elements[0],
              case let .chord(c1) = voice.elements[1]
        else { Issue.record("expected two chords"); return }
        #expect(c0.tremolo?.span == .between)
        #expect(c0.tremolo?.subtype == .r8)
        #expect(c1.tremolo == nil)
    }

    @Test func c8_with_no_follower_throws() throws {
        let xml = """
        <voice>
            <Chord>
                <durationType>half</durationType>
                <Tremolo><subtype>c16</subtype></Tremolo>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
            </Chord>
        </voice>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        #expect(throws: SheetMusicError.self) {
            _ = try Voice.decode(node, measureDuration: Fraction(4, 4))
        }
    }

    @Test func r16_unaffected_by_pairing_pass() throws {
        let xml = """
        <voice>
            <Chord>
                <durationType>quarter</durationType>
                <Tremolo><subtype>r16</subtype></Tremolo>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
            </Chord>
        </voice>
        """
        let node = try XMLTreeNode.parse(xml: xml)
        let voice = try Voice.decode(node, measureDuration: Fraction(4, 4))
        guard case let .chord(c) = voice.elements[0] else {
            Issue.record("expected chord"); return
        }
        #expect(c.tremolo?.span == .single)
        #expect(c.tremolo?.subtype == .r16)
    }
}
```

(Adapt `Voice.decode(...)` signature / call to whatever the existing helper accepts. See sibling tests under `Tests/SheetMusicTests/` for the canonical pattern.)

- [ ] **Step 3: Run, verify fails**

Run: `swift test --filter TremoloMSCXDecodeSecondPassTests`
Expected: 2 fail (follower keeps redundant tremolo; missing follower doesn't throw). The third (`r16_unaffected`) may already pass.

- [ ] **Step 4: Implement second pass in `MSCXDecoder+Voice.swift`**

After `elements` is fully built, insert a pass that mutates it. Add this helper at file scope (or as a private extension method):

```swift
private func resolveTremoloPairs(in elements: inout [VoiceElement]) throws {
    for i in elements.indices {
        guard case var .chord(start) = elements[i],
              let trem = start.tremolo,
              trem.span == .between
        else { continue }

        // Find the next .chord in this voice (skip non-chord elements).
        var followerIndex: Int? = nil
        for j in (i + 1) ..< elements.count {
            if case .chord = elements[j] {
                followerIndex = j
                break
            }
        }
        guard let fIdx = followerIndex,
              case var .chord(follower) = elements[fIdx]
        else {
            throw SheetMusicError.malformedScore(
                reason: "Two-note tremolo at element \(i) has no follower chord",
            )
        }
        // Clear the duplicate `<Tremolo>` MuseScore writes on the follower.
        follower.tremolo = nil
        elements[fIdx] = .chord(follower)
        // (start's span is already .between from the first pass — no edit needed.)
        _ = start
    }
}
```

Call `try resolveTremoloPairs(in: &elements)` from `Voice.decode` (or wherever `elements` is finalized).

- [ ] **Step 5: Run, verify all decode tests pass**

Run: `swift test --filter TremoloMSCXDecode`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift
git commit -m "mscx: resolve two-chord tremolo pairs in voice decode second pass"
```

---

### Task 1.4: MSCX encoder writes `<Tremolo>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` (or wherever voice-level chord encoding is dispatched)
- Test: `Tests/SheetMusicTests/TremoloMSCXEncodeTests.swift`

- [ ] **Step 1: Write failing round-trip test**

Create `Tests/SheetMusicTests/TremoloMSCXEncodeTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

struct TremoloMSCXEncodeTests {
    @Test func roundtrip_r16_single() throws {
        let original = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let node = original.encodeAsChord()
        let decoded = try Chord.decode(node)
        #expect(decoded.tremolo == original.tremolo)
    }

    @Test func roundtrip_c8_pair_emits_on_both_chords() throws {
        // A voice with a two-note tremolo: start.span = .between, follower
        // has tremolo == nil. Encode the voice → expect both <Chord>
        // elements to carry <Tremolo><subtype>c8</subtype>.
        let start = Chord(
            duration: .half,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .half,
            notes: [Note(pitch: 64, tpc: 18)],
            tremolo: nil,
        )
        let voice = Voice(elements: [.chord(start), .chord(follower)])
        let voiceNode = voice.encode(
            options: .init(),
            measureDuration: Fraction(4, 4),
        )
        let chords = voiceNode.all("Chord")
        #expect(chords.count == 2)
        #expect(chords[0].first("Tremolo")?.first("subtype")?.text == "c8")
        #expect(chords[1].first("Tremolo")?.first("subtype")?.text == "c8")
    }

    @Test func roundtrip_traditional_strokeStyle() throws {
        let original = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r32, strokeStyle: .traditional),
        )
        let node = original.encodeAsChord()
        let decoded = try Chord.decode(node)
        #expect(decoded.tremolo?.strokeStyle == .traditional)
    }
}
```

(Voice encoder API may differ — match the signature in `MSCXEncoder+Voice.swift`.)

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter TremoloMSCXEncodeTests`
Expected: FAIL (encoder emits no `<Tremolo>` block).

- [ ] **Step 3: Implement `<Tremolo>` emission**

Edit `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`. Replace the placeholder comment at the articulations location with a `<Tremolo>` block emitted between articulations and lyrics (MuseScore order: durationType → StemDirection → ChordLine / Articulation / Tremolo → Lyrics → Note):

Add a helper that builds the `<Tremolo>` XMLTreeNode:

```swift
private extension Tremolo {
    func encodeXML() -> XMLTreeNode {
        let token: String
        switch (span, subtype) {
        case (.single, .r8):  token = "r8"
        case (.single, .r16): token = "r16"
        case (.single, .r32): token = "r32"
        case (.between, .r8):  token = "c8"
        case (.between, .r16): token = "c16"
        case (.between, .r32): token = "c32"
        }
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: token),
        ]
        switch strokeStyle {
        case .default: break
        case .traditional:
            children.append(XMLTreeNode(name: "strokeStyle", text: "1"))
        case .z:
            children.append(XMLTreeNode(name: "strokeStyle", text: "2"))
        }
        return XMLTreeNode(name: "Tremolo", children: children)
    }
}
```

In `encodeAsChord`, after the articulations loop:

```swift
        if let trem = tremolo {
            children.append(trem.encodeXML())
        }
```

For two-note tremolo follower emission: `encodeAsChord` only knows about the chord's own `tremolo` field, which is `nil` on the follower. The voice-level encoder must inject the start chord's tremolo into the follower's encoding. Adjust `MSCXEncoder+Voice.swift` to thread an `injectedTremolo: Tremolo?` parameter into `encodeAsChord`:

Edit `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` signature:

```swift
    func encodeAsChord(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
        injectedTremolo: Tremolo? = nil,
    ) -> XMLTreeNode {
```

In the emission block:

```swift
        if let trem = tremolo ?? injectedTremolo {
            children.append(trem.encodeXML())
        }
```

Edit `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` to track the last seen start tremolo and pass it through:

```swift
var pendingFollowerTremolo: Tremolo?
for element in elements {
    switch element {
    case let .chord(chord) where !chord.notes.isEmpty:
        let inject = pendingFollowerTremolo
        pendingFollowerTremolo = nil
        if let trem = chord.tremolo, trem.span == .between {
            pendingFollowerTremolo = trem
        }
        children.append(chord.encodeAsChord(
            // ... existing args ...,
            injectedTremolo: inject,
        ))
    // ... other cases as today
    }
}
```

(Match exact loop structure to the existing file — this is the model, not the exact diff.)

- [ ] **Step 4: Run, verify passes**

Run: `swift test --filter TremoloMSCXEncodeTests`
Expected: PASS.

- [ ] **Step 5: Run full test suite (catch regression in MidiExportTests)**

Run: `swift test`
Expected: no regressions; MuseScore-equivalence fixtures still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift Tests/SheetMusicTests/TremoloMSCXEncodeTests.swift
git commit -m "mscx: encode <Tremolo> blocks and propagate to two-chord follower"
```

---

### Task 1.5: MIDI render — `tremoloSegments` helper

**Files:**
- Create: `Sources/SheetMusicMIDI/Render/MidiRenderer+Tremolo.swift`
- Test: `Tests/SheetMusicTests/TremoloMIDIRenderTests.swift`

- [ ] **Step 1: Write failing unit tests for `tremoloSegments`**

Create `Tests/SheetMusicTests/TremoloMIDIRenderTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct TremoloSegmentsTests {
    @Test func single_r16_on_quarter_yields_four_segments() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let segments = MidiRenderer.tremoloSegments(
            for: chord,
            nominalDuration: 480,
            followerChord: nil,
        )
        #expect(segments.count == 4)
        #expect(segments.allSatisfy { $0.pitches == [60] })
        #expect(segments.map(\.ticks) == [120, 120, 120, 120])
    }

    @Test func between_c8_alternates_pitch_sets() {
        let start = Chord(
            duration: .half,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .half,
            notes: [Note(pitch: 64, tpc: 18)],
        )
        let segments = MidiRenderer.tremoloSegments(
            for: start,
            nominalDuration: 480,
            followerChord: follower,
        )
        // r8 → 2 strokes per chord × 2 chords = 4 segments total,
        // alternating start.pitches, follower.pitches, start, follower.
        #expect(segments.count == 4)
        #expect(segments[0].pitches == [60])
        #expect(segments[1].pitches == [64])
        #expect(segments[2].pitches == [60])
        #expect(segments[3].pitches == [64])
        #expect(segments.allSatisfy { $0.ticks == 120 })
    }

    @Test func no_tremolo_yields_single_segment() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let segments = MidiRenderer.tremoloSegments(
            for: chord,
            nominalDuration: 480,
            followerChord: nil,
        )
        #expect(segments == [
            MidiRenderer.TremoloSegment(pitches: [60], ticks: 480),
        ])
    }
}
```

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter TremoloSegmentsTests`
Expected: FAIL (`tremoloSegments` not defined).

- [ ] **Step 3: Implement the helper**

Create `Sources/SheetMusicMIDI/Render/MidiRenderer+Tremolo.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Internal segment description for tremolo expansion. Each segment
    /// is a chord-shaped note-on/off pair; the voice walker emits MIDI
    /// events one per segment instead of one per `Chord`.
    struct TremoloSegment: Equatable {
        var pitches: [Int]
        var ticks: Int
    }

    /// Expand a chord's tremolo into a list of (pitchSet, durationTicks)
    /// segments. For no-tremolo chords returns a single segment matching
    /// the chord's nominal duration. For two-note tremolo, the caller
    /// must supply `followerChord`; the segment list covers BOTH chords'
    /// time-on-page, so the voice walker must mark the follower chord as
    /// consumed and skip its independent emission.
    ///
    /// Reference: `engraving/dom/tremolo.cpp` (`Tremolo::tremoloLen`) and
    /// `engraving/playback/renderer/internal/tremolorenderer.cpp`.
    static func tremoloSegments(
        for chord: Chord,
        nominalDuration: Int,
        followerChord: Chord?,
    ) throws -> [TremoloSegment] {
        guard let trem = chord.tremolo else {
            return [TremoloSegment(pitches: chord.notes.map(\.pitch),
                                   ticks: nominalDuration)]
        }
        let strokesPerChord = 1 << Int(trem.subtype.rawValue) // r8=2, r16=4, r32=8
        switch trem.span {
        case .single:
            let dur = nominalDuration / strokesPerChord
            return Array(
                repeating: TremoloSegment(
                    pitches: chord.notes.map(\.pitch),
                    ticks: dur,
                ),
                count: strokesPerChord,
            )
        case .between:
            guard let follower = followerChord else {
                throw SheetMusicError.malformedScore(
                    reason: "Two-note tremolo missing follower at render time",
                )
            }
            // Pair sounds for BOTH nominal durations combined, alternating.
            let totalDuration = nominalDuration * 2
            let totalStrokes = strokesPerChord * 2
            let perStroke = totalDuration / totalStrokes
            return (0 ..< totalStrokes).map { i in
                let src = i.isMultiple(of: 2) ? chord : follower
                return TremoloSegment(
                    pitches: src.notes.map(\.pitch),
                    ticks: perStroke,
                )
            }
        }
    }
}
```

Note the `throws`: the call site must `try` it; voice-walker integration handles the error by surfacing it to the renderer caller (`MidiRenderer.render` already throws).

Update the test signatures to use `try`:

```swift
@Test func single_r16_on_quarter_yields_four_segments() throws {
    ...
    let segments = try MidiRenderer.tremoloSegments(...)
```

(All three test methods become `throws`.)

- [ ] **Step 4: Run, verify passes**

Run: `swift test --filter TremoloSegmentsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Tremolo.swift Tests/SheetMusicTests/TremoloMIDIRenderTests.swift
git commit -m "midi: add tremoloSegments helper for stem-bar expansion"
```

---

### Task 1.6: MIDI render — voice-walker integration

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift` (only if a new entry point is needed — otherwise leave alone)
- Test: `Tests/SheetMusicTests/TremoloMIDIRenderTests.swift`

- [ ] **Step 1: Write failing end-to-end MIDI test**

Append to `Tests/SheetMusicTests/TremoloMIDIRenderTests.swift`:

```swift
struct TremoloVoiceRenderTests {
    @Test func single_r16_on_quarter_emits_four_noteOns() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        let (events, _) = MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Part(staves: [staff], instrument: .piano),
            channel: 0,
            division: 480,
        )
        let noteOns = events.filter {
            if case .noteOn = $0.event { return true }
            return false
        }
        #expect(noteOns.count == 4)
        let onTicks = noteOns.map(\.tick)
        #expect(onTicks == [0, 120, 240, 360])
    }

    @Test func between_c8_renders_alternating_pitch_quartet() throws {
        let start = Chord(
            duration: .half,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .half,
            notes: [Note(pitch: 64, tpc: 18)],
        )
        let measure = Measure(voices: [Voice(elements: [
            .chord(start), .chord(follower),
        ])])
        let staff = Staff(measures: [measure])
        let (events, _) = MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Part(staves: [staff], instrument: .piano),
            channel: 0,
            division: 480,
        )
        let pitchOns = events.compactMap { e -> Int? in
            if case let .noteOn(_, p, _) = e.event { return p }
            return nil
        }
        #expect(pitchOns == [60, 64, 60, 64])
    }
}
```

(Adapt `Part.init`, `Staff.init`, `Voice.init`, `Measure.init` to the existing signatures — search for a Helpers file or any existing voice-render test for the canonical shape.)

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter TremoloVoiceRenderTests`
Expected: FAIL — single-chord case produces 1 note-on; pair case produces 2.

- [ ] **Step 3: Integrate `tremoloSegments` into the voice walk**

Edit `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`. In `renderVoice(...)`, before the `for entry in plan` loop, declare an accumulator:

```swift
var consumedByTremolo: Set<Int> = []
```

In the inner `for (elementIndex, element) in effectiveVoice.elements.enumerated()` loop, gate skipping at the top:

```swift
if consumedByTremolo.contains(elementIndex) {
    consumedByTremolo.remove(elementIndex)
    // Still advance the tick cursor so subsequent elements land correctly.
    if case let .chord(c) = element {
        localTick += c.duration
            .resolved(in: measureDuration)
            .ticks(division: division)
    }
    continue
}
```

In the existing `case let .chord(chord):` branch, before the `glissandoEndPitch` lookup, branch on `chord.tremolo`:

```swift
if chord.tremolo != nil {
    let chordTicks = chord.duration
        .resolved(in: measureDuration)
        .ticks(division: division)
    // Resolve follower (the next .chord in this voice's elements).
    var followerChord: Chord? = nil
    if chord.tremolo?.span == .between {
        for j in (elementIndex + 1) ..< effectiveVoice.elements.count {
            if case let .chord(f) = effectiveVoice.elements[j] {
                followerChord = f
                consumedByTremolo.insert(j)
                break
            }
        }
    }
    let segments = try MidiRenderer.tremoloSegments(
        for: chord,
        nominalDuration: chordTicks,
        followerChord: followerChord,
    )
    var cursor = localTick
    let pitchShift = OttavaRanges.semitones(
        in: ottavaRanges,
        at: localTick + originalTickDelta,
    )
    let segVelocity = HairpinRamps.active(
        in: hairpinRamps,
        at: localTick + originalTickDelta,
    ).map { HairpinRamps.interpolate(ramp: $0, atOriginalTick: localTick + originalTickDelta) }
        ?? velocity
    for seg in segments {
        for pitch in seg.pitches {
            let shifted = min(127, max(0, pitch + pitchShift))
            events.append(TimedMidiEvent(
                tick: cursor,
                event: .noteOn(channel: channel, pitch: shifted, velocity: segVelocity),
            ))
            events.append(TimedMidiEvent(
                tick: cursor + seg.ticks - 1,
                event: .noteOff(channel: channel, pitch: shifted, velocity: 0),
            ))
        }
        cursor += seg.ticks
    }
    // For .single, advance localTick by the chord's own duration.
    // For .between, advance by the start's duration only — the
    // follower's tick advance is performed by the consumed-skip
    // branch above when the loop reaches the follower index.
    localTick += chordTicks
    continue
}
```

Note: `renderVoice` and `renderVoiceElement` are currently non-throwing. Promote the inner helper to `throws` and propagate up through `renderVoice`'s signature. Update every caller (search: `grep -rn "MidiRenderer.renderVoice" Sources Tests`).

If promoting `renderVoice` to `throws` is too invasive, alternative: catch the error at the integration point and convert to a renderer-level precondition failure — this matches the spec's "malformedScore" contract (we already validated pair existence at decode time, so the render-time error should be unreachable for valid scores).

Choose the throwing path: the decoder already throws, the existing renderer error surface is `SheetMusicError`, and bubbling stays consistent.

- [ ] **Step 4: Run, verify passes**

Run: `swift test --filter TremoloVoiceRenderTests`
Expected: PASS.

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: no regressions; particularly `MidiExportTests` (12 MuseScore-equivalence cases) still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift Tests/SheetMusicTests/TremoloMIDIRenderTests.swift
git commit -m "midi: render Chord.tremolo via tremoloSegments in voice walk"
```

---

### Task 1.7: Layout — emit `.tremoloBars`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
- Test: `Tests/SheetMusicTests/TremoloLayoutTests.swift`

- [ ] **Step 1: Write failing layout test**

Create `Tests/SheetMusicTests/TremoloLayoutTests.swift`:

```swift
import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

struct TremoloLayoutTests {
    @Test func single_r16_emits_tremoloBars_with_bar_count_2() throws {
        // Use whatever harness the existing LayoutArticulationTests uses.
        // The assertion: somewhere in the placed elements is one
        // .tremoloBars with anchor == .single and barCount == 2.
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let elements = layoutSingleChord(chord)
        let bars = elements.compactMap { el -> Int? in
            if case let .tremoloBars(anchor: .single, barCount: n) = el { return n }
            return nil
        }
        #expect(bars == [2])
    }

    @Test func between_c8_emits_tremoloBars_with_anchor_between() throws {
        // ...similar; expect .between anchor and barCount == 1.
    }
}

// Helper that wraps the chord in a minimal measure/staff/score and runs
// the layout engine end-to-end. Pattern this on `LayoutArticulationTests`.
private func layoutSingleChord(_ chord: Chord) -> [LayoutElement] { /* … */ }
```

(Skim `Tests/SheetMusicTests/LayoutArticulationTests.swift` to copy the minimal layout-driving harness.)

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter TremoloLayoutTests`
Expected: FAIL — `LayoutElement.tremoloBars` doesn't exist.

- [ ] **Step 3: Add `.tremoloBars` case and `TremoloAnchor` to `LayoutElement.swift`**

In `Sources/SheetMusicLayout/Layout/LayoutElement.swift`, before the `enum ArticulationKind` nested declaration:

```swift
    /// Beamed-stem tremolo bars. Bar count comes from
    /// `Tremolo.Subtype.rawValue` (1, 2, or 3). Slant is fixed at +12°
    /// for v1 (a flat slant matches the MuseScore default sufficiently
    /// for visual review). Drawn as slanted rectangles using
    /// `metrics.beamThickness` and `metrics.beamSpacing`.
    case tremoloBars(anchor: TremoloAnchor, barCount: Int)
```

Add a top-level `TremoloAnchor` enum in the same file (under the LayoutElement enum body but in file scope, alongside `StemDirection`):

```swift
/// Anchor describing where a `.tremoloBars` element draws its bars.
/// Stem coordinates are pre-computed by the placement pass so the
/// renderer does not need to look up the source chord.
@available(macOS 15.0, *)
public enum TremoloAnchor: Sendable, Equatable {
    /// Bars cross a single stem at its midpoint, centered along
    /// `stemTop`-`stemBottom`.
    case single(stemTop: CGPoint, stemBottom: CGPoint)
    /// Bars span between two stems (two-chord tremolo). Coordinates
    /// describe the *midpoint* of each chord's stem.
    case between(leftStemMid: CGPoint, rightStemMid: CGPoint)
}
```

- [ ] **Step 4: Emit `.tremoloBars` from placement**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`, find the loop that walks chords inside a measure and emits chord-related elements (stems, accidentals, articulations). After the stem geometry is computed for a chord:

```swift
if let trem = chord.tremolo {
    let barCount = Int(trem.subtype.rawValue)
    let anchor: TremoloAnchor
    switch trem.span {
    case .single:
        anchor = .single(
            stemTop: stemTopPoint,
            stemBottom: stemBottomPoint,
        )
    case .between:
        // Find the follower chord's stem geometry, computed in the
        // same measure-placement pass earlier or look ahead — pick
        // whichever direction matches the existing iteration order.
        guard let follower = lookaheadStem(for: chord, in: measureChords)
        else { continue } // unreachable in a valid score; decoder already validated
        anchor = .between(
            leftStemMid: midpoint(of: stemTopPoint, stemBottomPoint),
            rightStemMid: midpoint(of: follower.top, follower.bottom),
        )
    }
    elements.append(.tremoloBars(anchor: anchor, barCount: barCount))
}
```

(Naming of `stemTopPoint` / `stemBottomPoint` / `measureChords` matches existing locals — adjust to whatever the surrounding code uses. The `lookaheadStem(for:in:)` helper and `midpoint(of:_:)` may need a small free function or inline expression; add as needed.)

- [ ] **Step 5: Run, verify passes**

Run: `swift test --filter TremoloLayoutTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Tests/SheetMusicTests/TremoloLayoutTests.swift
git commit -m "layout: emit .tremoloBars elements for Chord.tremolo"
```

---

### Task 1.8: UI renderer for `.tremoloBars`

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/TremoloRenderer.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`

- [ ] **Step 1: Add `TremoloRenderer.swift`**

Create `Sources/SheetMusicUI/Rendering/TremoloRenderer.swift`:

```swift
import CoreGraphics
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Draws beamed-stem tremolo bars for a `.tremoloBars` element. Each
/// bar is a slanted rectangle of thickness `metrics.beamThickness`,
/// spaced by `metrics.beamSpacing`. Slant is fixed at +12° for v1 —
/// MuseScore uses chord-specific slant heuristics but the constant
/// matches the default 90% of the time and avoids carrying beam
/// state into the tremolo emitter.
@available(macOS 15.0, iOS 17.0, *)
enum TremoloRenderer {
    static func draw(
        anchor: TremoloAnchor,
        barCount: Int,
        metrics: StaffMetrics,
        in context: inout GraphicsContext,
    ) {
        let center: CGPoint
        let halfWidth: CGFloat
        switch anchor {
        case let .single(top, bottom):
            center = CGPoint(
                x: top.x,
                y: (top.y + bottom.y) / 2,
            )
            halfWidth = metrics.spatium * 0.9
        case let .between(left, right):
            center = CGPoint(
                x: (left.x + right.x) / 2,
                y: (left.y + right.y) / 2,
            )
            halfWidth = (right.x - left.x) / 2 - metrics.spatium * 0.2
        }
        let slantDy = halfWidth * tan(.pi / 15) // +12° (≈0.2126)
        let thickness = metrics.beamThickness
        let spacing = metrics.beamSpacing
        for i in 0 ..< barCount {
            let offsetY = CGFloat(i) * spacing
                - CGFloat(barCount - 1) / 2 * spacing
            var path = Path()
            let p1 = CGPoint(x: center.x - halfWidth,
                             y: center.y + offsetY - slantDy)
            let p2 = CGPoint(x: center.x + halfWidth,
                             y: center.y + offsetY + slantDy)
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(.primary), lineWidth: thickness)
        }
    }
}
```

(The exact rendering API — `GraphicsContext` vs. SwiftUI `Path` — depends on what the rest of `ScoreLayerBuilder+*.swift` uses. Mirror the closest existing renderer such as `BeamRenderer.swift`.)

- [ ] **Step 2: Dispatch from `ScoreLayerBuilder+Element.swift`**

Locate the element-switch that dispatches `case .beam(...)`. Add `case .tremoloBars(anchor: let anchor, barCount: let n):` next to it, calling `TremoloRenderer.draw(...)`.

- [ ] **Step 3: Build whole package**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Manual visual check via `RenderPreviews`**

(Optional — useful but not blocking.) If a tremolo fixture exists under `Tests/SheetMusicTests/Resources/`, render it via the dev executable:

```bash
swift run RenderPreviews --input Tests/SheetMusicTests/Resources/<tremolo>.mscx --output /tmp/tremolo.png
```

Inspect `/tmp/tremolo.png` and confirm bars draw at the expected location and count.

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/TremoloRenderer.swift Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
git commit -m "ui: render .tremoloBars layout elements as slanted bars"
```

---

### Task 1.9: Run MuseScore-equivalence regression sweep

- [ ] **Step 1: Run focused regression test**

Run: `swift test --filter MidiExportTests`
Expected: 12/12 PASS — `<Tremolo>` blocks in any fixture round-trip through the new decode/encode/render path.

- [ ] **Step 2: Run swiftlint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors. Address any new violations introduced by Phase 1 files (file_length, function_body_length, function_parameter_count).

- [ ] **Step 3: Phase 1 checkpoint commit (if anything outstanding)**

If `swiftlint` autofix or noise cleanup added trailing changes, commit:

```bash
git add -p
git commit -m "tremolo: lint cleanup"
```

Otherwise skip.

---

## Phase 2 — MusicXML `<glissando>` / `<slide>` import

### Task 2.1: Hand-author MusicXML fixtures

**Files:**
- Create: `Tests/SheetMusicTests/Resources/glissando-wavy.musicxml`
- Create: `Tests/SheetMusicTests/Resources/slide-portamento.musicxml`
- Create: `Tests/SheetMusicTests/Resources/glissando-unmatched-stop.musicxml`

- [ ] **Step 1: Write `glissando-wavy.musicxml`**

Create `Tests/SheetMusicTests/Resources/glissando-wavy.musicxml`:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="3.1">
  <part-list>
    <score-part id="P1"><part-name>Voice</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <key><fifths>0</fifths></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
        <clef><sign>G</sign><line>2</line></clef>
      </attributes>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>2</duration>
        <type>half</type>
        <notations>
          <glissando type="start" line-type="wavy" number="1"/>
        </notations>
      </note>
      <note>
        <pitch><step>G</step><octave>4</octave></pitch>
        <duration>2</duration>
        <type>half</type>
        <notations>
          <glissando type="stop" line-type="wavy" number="1"/>
        </notations>
      </note>
    </measure>
  </part>
</score-partwise>
```

- [ ] **Step 2: Write `slide-portamento.musicxml`**

Create `Tests/SheetMusicTests/Resources/slide-portamento.musicxml`:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="3.1">
  <part-list>
    <score-part id="P1"><part-name>Voice</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <key><fifths>0</fifths></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
        <clef><sign>G</sign><line>2</line></clef>
      </attributes>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>2</duration>
        <type>half</type>
        <notations>
          <slide type="start" line-type="solid" number="1"/>
        </notations>
      </note>
      <note>
        <pitch><step>G</step><octave>4</octave></pitch>
        <duration>2</duration>
        <type>half</type>
        <notations>
          <slide type="stop" line-type="solid" number="1"/>
        </notations>
      </note>
    </measure>
  </part>
</score-partwise>
```

- [ ] **Step 3: Write `glissando-unmatched-stop.musicxml`**

Create `Tests/SheetMusicTests/Resources/glissando-unmatched-stop.musicxml`:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="3.1">
  <part-list>
    <score-part id="P1"><part-name>Voice</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <key><fifths>0</fifths></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
        <clef><sign>G</sign><line>2</line></clef>
      </attributes>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>2</duration>
        <type>half</type>
      </note>
      <note>
        <pitch><step>G</step><octave>4</octave></pitch>
        <duration>2</duration>
        <type>half</type>
        <notations>
          <glissando type="stop" line-type="wavy" number="1"/>
        </notations>
      </note>
    </measure>
  </part>
</score-partwise>
```

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/Resources/glissando-wavy.musicxml Tests/SheetMusicTests/Resources/slide-portamento.musicxml Tests/SheetMusicTests/Resources/glissando-unmatched-stop.musicxml
git commit -m "test: add MusicXML glissando/slide import fixtures"
```

---

### Task 2.2: Wire decoder state and emission

**Files:**
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder.swift` (or wherever the per-part decode loop holds state)
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift`
- Test: `Tests/SheetMusicTests/MusicXMLGlissandoTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/MusicXMLGlissandoTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

struct MusicXMLGlissandoTests {
    @Test func wavy_glissando_attaches_to_start_note_as_chromatic_wavy() throws {
        let url = Bundle.module.url(
            forResource: "glissando-wavy", withExtension: "musicxml",
        )!
        let score = try MusicXMLImporter.importScore(at: url)
        let firstChord = firstChord(of: score)
        let note = firstChord.notes.first!
        #expect(note.glissando?.style == .chromatic)
        #expect(note.glissando?.visualType == .wavy)
    }

    @Test func slide_attaches_as_portamento() throws {
        let url = Bundle.module.url(
            forResource: "slide-portamento", withExtension: "musicxml",
        )!
        let score = try MusicXMLImporter.importScore(at: url)
        let firstChord = firstChord(of: score)
        let note = firstChord.notes.first!
        #expect(note.glissando?.style == .portamento)
    }

    @Test func unmatched_stop_does_not_attach_or_crash() throws {
        let url = Bundle.module.url(
            forResource: "glissando-unmatched-stop", withExtension: "musicxml",
        )!
        let score = try MusicXMLImporter.importScore(at: url)
        for chord in allChords(of: score) {
            for note in chord.notes {
                #expect(note.glissando == nil)
            }
        }
    }

    private func firstChord(of score: Score) -> Chord {
        let staff = score.parts.first!.staves.first!
        for element in staff.measures[0].voices[0].elements {
            if case let .chord(c) = element { return c }
        }
        preconditionFailure("no chord")
    }

    private func allChords(of score: Score) -> [Chord] {
        var chords: [Chord] = []
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            if case let .chord(c) = element { chords.append(c) }
                        }
                    }
                }
            }
        }
        return chords
    }
}
```

(Adapt `MusicXMLImporter.importScore` and `Bundle.module` to existing helpers — see `Tests/SheetMusicTests/MusicXMLImportTests.swift` for the canonical pattern. The Package manifest must list the new `.musicxml` files under the test target's resources; SwiftPM glob defaults usually handle this, verify with `swift test` after fixtures are committed.)

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter MusicXMLGlissandoTests`
Expected: FAIL (decoder ignores `<glissando>` / `<slide>`).

- [ ] **Step 3: Add pending-dict state to the per-part decode session**

Identify the per-part decoder owner. The `pendingGlides` field lives there because cross-part glissandi are invalid. Find via `grep -n "func decodePart\|var pending\|MusicXMLDecoder " Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder*.swift`.

Add:

```swift
struct PendingGlide {
    let style: Glissando.Style
    let visualType: Glissando.VisualType
    let text: String?
    // (measure, voiceIndex, elementIndex within voice) — enough to
    // mutate the start chord's first note after the fact.
    let location: PendingGlideLocation
}

struct PendingGlideLocation {
    let measureIndex: Int
    let voiceIndex: Int
    let elementIndex: Int
}

struct GlideKey: Hashable {
    enum Kind: Hashable { case glissando, slide }
    let kind: Kind
    let number: Int
}

// On the per-part decoder state:
var pendingGlides: [GlideKey: PendingGlide] = [:]
```

Clear `pendingGlides` at the close of a `<part>` (wherever the per-part loop ends).

- [ ] **Step 4: Parse `<glissando>` / `<slide>` inside `<notations>`**

Edit `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift`. The current `decodeNote` returns a `Decoded.new([VoiceElement])` or `.foldIntoLastChord`. Glissando attachment is *retroactive* (only known once the stop note is seen), so the decoder must either:

A) Carry mutation forward by mutating prior emitted voice elements after the fact, or
B) Return a "post-decode patch" that the caller applies.

Use (A): record only the structural location (measure/voice/elementIndex) when the start note is decoded, and on stop, mutate the live voice array.

Add the parser:

```swift
private static func decodeGlide(
    _ notations: XMLTreeNode,
    pending: inout [GlideKey: PendingGlide],
    currentLocation: PendingGlideLocation,
    score: inout PartialScore,
) {
    for kindNode in notations.children
        where kindNode.name == "glissando" || kindNode.name == "slide"
    {
        let kind: GlideKey.Kind =
            kindNode.name == "glissando" ? .glissando : .slide
        let number = Int(kindNode.attributes["number"] ?? "1") ?? 1
        let type = kindNode.attributes["type"] ?? ""
        let lineType = kindNode.attributes["line-type"]
        let visualType: Glissando.VisualType =
            (lineType == "wavy") ? .wavy : .straight
        let style: Glissando.Style =
            (kind == .glissando) ? .chromatic : .portamento
        let text = kindNode.text.isEmpty ? nil : kindNode.text
        let key = GlideKey(kind: kind, number: number)
        switch type {
        case "start":
            pending[key] = PendingGlide(
                style: style,
                visualType: visualType,
                text: text,
                location: currentLocation,
            )
        case "stop":
            guard let start = pending.removeValue(forKey: key) else {
                continue // unmatched stop → silently drop (permissive)
            }
            score.attachGlissando(
                Glissando(
                    style: start.style,
                    visualType: start.visualType,
                    text: start.text,
                ),
                at: start.location,
            )
        default:
            continue
        }
    }
}
```

`PartialScore.attachGlissando(_:at:)` is a new helper that writes into the in-flight voice element list. Pattern this on existing tie / arpeggio attachment helpers — `grep -n "func attach\|tieForward\|attachGlissando" Sources/SheetMusicMusicXML/Decoders/`.

Call `decodeGlide` from the `<notations>` walk inside `decodeNote` (or from the caller that processes each `<note>`), wiring through the current decoder's `pendingGlides` and the location of the just-emitted chord.

- [ ] **Step 5: Clear pending dict at `</part>`**

In the per-part decode loop (likely `MusicXMLDecoder+Part.swift` or the main decoder), at the end of processing a part:

```swift
pendingGlides.removeAll(keepingCapacity: false)
```

- [ ] **Step 6: Run, verify passes**

Run: `swift test --filter MusicXMLGlissandoTests`
Expected: PASS.

- [ ] **Step 7: Run full test suite**

Run: `swift test`
Expected: no regressions in MusicXML import tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder.swift Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Part.swift Tests/SheetMusicTests/MusicXMLGlissandoTests.swift
git commit -m "musicxml: import <glissando> and <slide> as Note.glissando"
```

---

## Phase 3 — Diatonic glissando key signature awareness

### Task 3.1: `KeySignature.diatonicPitchClasses`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/KeySignature.swift`
- Test: `Tests/SheetMusicTests/DiatonicPitchClassesTests.swift`

- [ ] **Step 1: Write failing tests for all 15 entries in the spec table**

Create `Tests/SheetMusicTests/DiatonicPitchClassesTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

struct DiatonicPitchClassesTests {
    private func pcs(_ key: Int) -> Set<Int> {
        KeySignature(concertKey: key).diatonicPitchClasses
    }

    @Test func cMajor_zero_sharps() {
        #expect(pcs(0) == [0, 2, 4, 5, 7, 9, 11])
    }
    @Test func gMajor_plus_one() {
        #expect(pcs(1) == [0, 2, 4, 6, 7, 9, 11])
    }
    @Test func dMajor_plus_two() {
        #expect(pcs(2) == [1, 2, 4, 6, 7, 9, 11])
    }
    @Test func aMajor_plus_three() {
        #expect(pcs(3) == [1, 2, 4, 6, 8, 9, 11])
    }
    @Test func eMajor_plus_four() {
        #expect(pcs(4) == [1, 3, 4, 6, 8, 9, 11])
    }
    @Test func bMajor_plus_five() {
        #expect(pcs(5) == [1, 3, 4, 6, 8, 10, 11])
    }
    @Test func fSharpMajor_plus_six() {
        #expect(pcs(6) == [1, 3, 5, 6, 8, 10, 11])
    }
    @Test func cSharpMajor_plus_seven() {
        #expect(pcs(7) == [0, 1, 3, 5, 6, 8, 10])
    }
    @Test func fMajor_minus_one() {
        #expect(pcs(-1) == [0, 2, 4, 5, 7, 9, 10])
    }
    @Test func bFlatMajor_minus_two() {
        #expect(pcs(-2) == [0, 2, 3, 5, 7, 9, 10])
    }
    @Test func eFlatMajor_minus_three() {
        #expect(pcs(-3) == [0, 2, 3, 5, 7, 8, 10])
    }
    @Test func aFlatMajor_minus_four() {
        #expect(pcs(-4) == [0, 1, 3, 5, 7, 8, 10])
    }
    @Test func dFlatMajor_minus_five() {
        #expect(pcs(-5) == [0, 1, 3, 5, 6, 8, 10])
    }
    @Test func gFlatMajor_minus_six() {
        #expect(pcs(-6) == [1, 3, 5, 6, 8, 10, 11])
    }
    @Test func cFlatMajor_minus_seven() {
        #expect(pcs(-7) == [1, 3, 4, 6, 8, 10, 11])
    }

    @Test func every_signature_returns_exactly_seven_pcs() {
        for k in -7 ... 7 {
            #expect(pcs(k).count == 7)
        }
    }
}
```

- [ ] **Step 2: Run, verify fails**

Run: `swift test --filter DiatonicPitchClassesTests`
Expected: FAIL (`diatonicPitchClasses` not defined).

- [ ] **Step 3: Implement the helper**

Append to `Sources/SheetMusicCore/Score/KeySignature.swift`:

```swift
public extension KeySignature {
    /// 7-tone pitch class set (0…11) of the diatonic scale implied
    /// by this signature. Major / minor / modal share the same
    /// signature so a single mapping suffices.
    ///
    /// Starts from the C-major PC set `{0, 2, 4, 5, 7, 9, 11}` and
    /// applies one alteration per accidental, following the circle of
    /// fifths: sharps F → C → G → D → A → E → B (each PC raised by 1);
    /// flats B → E → A → D → G → C → F (each PC lowered by 1).
    var diatonicPitchClasses: Set<Int> {
        // Pitch classes of the diatonic-note names in their
        // C-major positions, indexed F C G D A E B (sharp order).
        // F=5, C=0, G=7, D=2, A=9, E=4, B=11.
        let sharpOrder = [5, 0, 7, 2, 9, 4, 11]
        // Flats apply in the reverse order: B E A D G C F.
        let flatOrder: [Int] = sharpOrder.reversed()
        var set: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
        if concertKey >= 0 {
            for i in 0 ..< concertKey {
                let pc = sharpOrder[i]
                set.remove(pc)
                set.insert((pc + 1) % 12)
            }
        } else {
            for i in 0 ..< -concertKey {
                let pc = flatOrder[i]
                set.remove(pc)
                set.insert((pc + 11) % 12)
            }
        }
        return set
    }
}
```

- [ ] **Step 4: Run, verify all 16 tests pass**

Run: `swift test --filter DiatonicPitchClassesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/KeySignature.swift Tests/SheetMusicTests/DiatonicPitchClassesTests.swift
git commit -m "core: add KeySignature.diatonicPitchClasses (circle of fifths)"
```

---

### Task 3.2: Switch glissando renderer to `KeySignature.diatonicPitchClasses`

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+GlissandoMath.swift`
- Test: `Tests/SheetMusicTests/GlissandoDiatonicKeyTests.swift`

- [ ] **Step 1: Write failing renderer-behavior tests**

Create `Tests/SheetMusicTests/GlissandoDiatonicKeyTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct GlissandoDiatonicKeyTests {
    @Test func cMajor_includes_E_not_Eflat() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 60, endPitch: 72, keySignature: 0,
        )
        let absolutePitches = offsets.map { 60 + $0 }
        #expect(absolutePitches.contains(64))   // E4
        #expect(!absolutePitches.contains(63))  // Eb4
    }

    @Test func gMajor_includes_FSharp_not_F() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 67, endPitch: 79, keySignature: 1,
        )
        let absolutePitches = offsets.map { 67 + $0 }
        #expect(absolutePitches.contains(78))   // F#5
        #expect(!absolutePitches.contains(77))  // F5
    }

    @Test func fMinor_includes_Ab_Bb_Db_Eb() {
        // F minor / Ab major has signature -4: PCs {0,1,3,5,7,8,10}.
        // From F3 (53) to F4 (65) the in-key intermediates are
        // G3(55), Ab3(56), Bb3(58), C4(60), Db4(61), Eb4(63).
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 53, endPitch: 65, keySignature: -4,
        )
        let absolutePitches = Set(offsets.map { 53 + $0 })
        #expect(absolutePitches.contains(56))   // Ab3
        #expect(absolutePitches.contains(58))   // Bb3
        #expect(absolutePitches.contains(61))   // Db4
        #expect(absolutePitches.contains(63))   // Eb4
        #expect(!absolutePitches.contains(57))  // A3 (not in F minor)
        #expect(!absolutePitches.contains(62))  // D4 (not in F minor)
    }
}
```

- [ ] **Step 2: Run, verify all pass or fail consistently with old behaviour**

Run: `swift test --filter GlissandoDiatonicKeyTests`
Expected: The G-major and F-minor cases may already pass under the existing `majorScalePCs` (which is mathematically equivalent for the 7-tone set). Reconfirm: these tests pin the *intended* behaviour regardless of which implementation produces it. Note any unexpected failure; the most likely failure is the F minor case if the old formula produced a different scale set.

- [ ] **Step 3: Switch the renderer to use `diatonicPitchClasses`**

Edit `Sources/SheetMusicMIDI/Render/MidiRenderer+GlissandoMath.swift`.

Replace the `.diatonic` branch:

```swift
        case .diatonic:
            return filteredOffsets(
                startPitch: startPitch,
                endPitch: endPitch,
                direction: direction,
                pcs: KeySignature(concertKey: keySignature)
                    .diatonicPitchClasses,
            )
```

Delete the now-unused `majorScalePCs(forKeySignature:)` static helper. Update the doc comment at the head of the file to describe the new key-signature-derived behaviour:

```swift
        /// `.diatonic` walks the 7-tone PC set implied by the active key
        /// signature via `KeySignature.diatonicPitchClasses`. This is a
        /// pitch-class approximation of MuseScore's line-based diatonic
        /// logic (`engraving/dom/glissando.cpp:222`): we don't track
        /// staff lines, so Tab clef and unusual non-five-line staves
        /// can diverge. Acceptable for v1.
```

- [ ] **Step 4: Run, verify all pass**

Run: `swift test --filter GlissandoDiatonicKeyTests`
Run: `swift test --filter GlissandoPitchOffsetTests`
Expected: both PASS. (The existing `GlissandoPitchOffsetTests` has a G-major case that must continue to pass under the new helper — the algorithms produce the same PCs.)

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+GlissandoMath.swift Tests/SheetMusicTests/GlissandoDiatonicKeyTests.swift
git commit -m "midi: route .diatonic glissando through KeySignature.diatonicPitchClasses"
```

---

## Phase wrap

### Task 4.1: Cross-target build verification

Per [[feedback_example_app_outside_swiftpm]], `swift build`/`swift test` don't compile the Example app — verify both targets after public-enum additions (a new `LayoutElement` case is the relevant gate here for Phase 1).

- [ ] **Step 1: Build SwiftPM package**

Run: `swift build`
Expected: success.

- [ ] **Step 2: Build Mac example**

Run:
```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
    -scheme SheetMusicExampleMac \
    -destination 'platform=macOS' \
    -skipPackagePluginValidation \
    build
```
Expected: success.

- [ ] **Step 3: Build iOS example**

Run:
```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
    -scheme SheetMusicExample \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation \
    build
```
Expected: success.

- [ ] **Step 4: SwiftLint sweep**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 5: Commit lint fixes if needed**

If new long files exceeded the 300-line cap, split per CLAUDE.md convention.

```bash
git add -p
git commit -m "tremolo+glissando: lint cleanup"
```

---

## Notes for the executor

- **Decode tests rely on `XMLTreeNode.parse(xml:)`**: this helper may not exist verbatim. The Tests target has a sibling pattern — search for `XMLTreeNode.parse` or `parseXML` under `Tests/SheetMusicTests/` and adapt. If no such helper exists, use `XMLTreeParser` (from `SheetMusicXMLTools`) directly with an inline string-to-data conversion. Don't introduce a new test-only helper unless multiple tests need it.

- **`swift test` resource discovery**: when adding new `.musicxml` files under `Tests/SheetMusicTests/Resources/`, ensure SwiftPM picks them up. The package manifest may already declare a glob; if not, add the new files explicitly to the test target's `resources:` array.

- **Voice encoder dispatch shape**: `MSCXEncoder+Voice.swift` is currently split across `MSCXEncoder+Voice.swift`, `MSCXEncoder+Voice+Helpers.swift`, `MSCXEncoder+Voice+Ties.swift`. The pending-tremolo state for follower emission lives wherever the per-element loop is — likely the primary `+Voice.swift` file.

- **`MidiRenderer.renderVoice` throws migration**: this is the most invasive integration change. Audit call sites with `grep -rn "MidiRenderer.renderVoice\|renderVoice(" Sources Tests` and ensure each handles the new `throws`. The renderer top-level entry point already throws `SheetMusicError`, so bubbling up should be straightforward.

- **`@_exported import` + `@testable`**: per CLAUDE.md, each sub-library needs an explicit `@testable import` in test files. Phase 1 test files need `@testable import SheetMusicCore`, `SheetMusicMSCX`, `SheetMusicMIDI`, `SheetMusicLayout`, `SheetMusicUI` depending on which target they cover.

- **No surprise refactors**: per [[feedback_swift_enum_case_addition_scope]], the `LayoutElement.tremoloBars` case addition (Task 1.7) breaks every exhaustive switch over `LayoutElement`. Each switch site must be updated in the same task — don't push it to a follow-up. Search: `grep -rn "switch.*LayoutElement\|case .beam\|case .note(" Sources/SheetMusicUI Sources/SheetMusicLayout` for the call sites.

- **Big-task autonomy**: per [[feedback_big_task_autonomy]], proceed phase-by-phase without per-step confirmation once execution begins. Stop only on test failures, public-API surface questions, or unexpected lint violations.
