import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("SetDynamic")
struct SetDynamicTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements.values
    }

    @Test("a dynamic is inserted right before its chord, with MuseScore's default velocity")
    func inserts() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4, D4, r, r]
        _ = try SetDynamic(at: Self.slot(0, 2), subtype: "ff").apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[2] == .dynamic(Dynamic(subtype: "ff", velocity: 112)))
        #expect(elements[3] == .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])))
        #expect(SetDynamic.current(at: Self.slot(0, 3), in: score)?.subtype == "ff")
    }

    @Test("a dynamic already before the chord is replaced in place, keeping its font overrides")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                var elements = staffValue.measures[0].voices[0].elements.values
                elements.insert(
                    .dynamic(Dynamic(subtype: "p", velocity: 49, properties: TextProperties(size: 14))), at: 1,
                )
                staffValue.measures[0].voices[0].elements = IdentifiedArray(elements)
            }
        }
        // [ts, dyn, C4, D4, r, r]
        _ = try SetDynamic(at: Self.slot(0, 2), subtype: "mf").apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[1] == .dynamic(Dynamic(subtype: "mf", velocity: 80, properties: TextProperties(size: 14))))
    }

    @Test("the dynamic is found past a fermata in the same run")
    func findsThroughTheRun() throws {
        var score = EditingFixtures.parityFixture()
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                var elements = staffValue.measures[0].voices[0].elements.values
                elements.insert(
                    contentsOf: [
                        .dynamic(Dynamic(subtype: "p", velocity: 49)), .fermata(Fermata(subtype: "fermataAbove")),
                    ],
                    at: 1,
                )
                staffValue.measures[0].voices[0].elements = IdentifiedArray(elements)
            }
        }
        // [ts, dyn, fermata, C4, D4, r, r]
        _ = try SetDynamic(at: Self.slot(0, 3), subtype: nil).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[1] == .fermata(Fermata(subtype: "fermataAbove")))
    }

    @Test("nil removes the dynamic; the inverses restore the score exactly")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetDynamic(at: Self.slot(0, 1), subtype: "p").apply(to: &score)
        let written = score
        let clearInverse = try SetDynamic(at: Self.slot(0, 2), subtype: nil).apply(to: &score)
        #expect(score == before)
        _ = try clearInverse.apply(to: &score)
        #expect(score == written)
        _ = try writeInverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a rest, a non-timed element, a missing element and a clear with nothing to clear are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let rest = #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 3), subtype: "p").apply(to: &score)
        }
        #expect(Self.reason(of: rest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 0), subtype: "p").apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 9), subtype: "p").apply(to: &score)
        }
        let nothing = #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 1), subtype: nil).apply(to: &score)
        }
        #expect(Self.reason(of: nothing) == .targetNotFound(Self.slot(0, 1)))
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}

/// `SetDynamic` sets a dynamic's text with its subtype, as MuseScore's drop does (`Dynamic::drop`,
/// `engraving/dom/dynamic.cpp:318-325`): a new subtype never keeps a stale text (F4.6), the palette's own subtype over
/// a dynamic with its own text brings back the plain one, and a copied text — MuseScore xml text — is written back
/// whole (F4.7).
@Suite("SetDynamic — the dynamic's own text")
struct SetDynamicTextTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let subitoXML = "subito <sym>dynamicPiano</sym>"

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func subitoP() -> Dynamic {
        Dynamic(
            subtype: "p", velocity: 49, text: "subito ", preservedTextMarkup: PreservedTextMarkup(xmlText: subitoXML),
        )
    }

    /// `parityFixture`'s first bar `[ts, C4, D4, r, r]` with `dynamic` before C4: `[ts, dyn, C4, D4, r, r]`.
    private static func score(with dynamic: Dynamic) -> Score {
        var score = EditingFixtures.parityFixture()
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                var elements = staff.measures[0].voices[0].elements.values
                elements.insert(.dynamic(dynamic), at: 1)
                staff.measures[0].voices[0].elements = IdentifiedArray(elements)
            }
        }
        return score
    }

    private static func dynamic(in score: Score) -> Dynamic? {
        if case let .dynamic(dynamic) = score.parts[0].staves[0].measures[0].voices[0].elements.values[1] {
            return dynamic
        }
        return nil
    }

    @Test("a new subtype drops the old text (F4.6)")
    func newSubtypeDropsTheText() throws {
        var score = Self.score(with: Self.subitoP())
        _ = try SetDynamic(at: Self.slot(2), subtype: "f").apply(to: &score)
        #expect(Self.dynamic(in: score) == Dynamic(subtype: "f", velocity: 96))
    }

    @Test("the palette's own subtype over a dynamic with its own text is a write, back to the plain dynamic")
    func paletteSubtypeOverOwnTextIsAWrite() {
        let session = ScoreEditSession(score: Self.score(with: Self.subitoP()))
        #expect(session.apply(.setDynamic(at: Self.slot(2), subtype: "p")))
        #expect(Self.dynamic(in: session.score) == Dynamic(subtype: "p", velocity: 49))
        #expect(!session.apply(.setDynamic(at: Self.slot(2), subtype: "p")))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("a text written as MuseScore xml text arrives whole: words, glyph, formatting; plain words stay plain")
    func writesXMLText() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetDynamic(at: Self.slot(1), subtype: "p", xmlText: Self.subitoXML).apply(to: &score)
        let written = try #require(Self.dynamic(in: score))
        #expect(written.subtype == "p")
        #expect(written.velocity == 49)
        #expect(written.text == "subito ")
        #expect(written.customXMLText == Self.subitoXML)
        #expect(written.richText?.lines == [[
            .text("subito ", RichTextFormat()), .symbol(name: "dynamicPiano", RichTextFormat()),
        ]])
        var plainScore = EditingFixtures.parityFixture()
        _ = try SetDynamic(at: Self.slot(1), subtype: "p", xmlText: "subito p").apply(to: &plainScore)
        let plain = try #require(Self.dynamic(in: plainScore))
        #expect(plain.text == "subito p")
        #expect(plain.preservedTextMarkup == nil)
    }

    @Test("a write keeps what it does not set: play flag, change speed, voice assignment, font overrides, visibility")
    func keepsTheElementsOwnProperties() throws {
        var dynamic = Self.subitoP()
        dynamic.playsBack = false
        dynamic.velocityChangeSpeed = .slow
        dynamic.voiceAssignment = .currentVoiceOnly
        dynamic.properties = TextProperties(size: 14)
        dynamic.visible = false
        var score = Self.score(with: dynamic)
        _ = try SetDynamic(at: Self.slot(2), subtype: "fp").apply(to: &score)
        let written = try #require(Self.dynamic(in: score))
        #expect(!written.playsBack)
        #expect(written.velocityChangeSpeed == .slow)
        #expect(written.voiceAssignment == .currentVoiceOnly)
        #expect(written.properties == TextProperties(size: 14))
        #expect(!written.visible)
        #expect(written.text == nil)
    }

    @Test("undo brings the text back")
    func undoRestoresTheText() throws {
        var score = Self.score(with: Self.subitoP())
        let before = score
        let inverse = try SetDynamic(at: Self.slot(2), subtype: "f").apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a dynamic whose subtype changed saves without its stale text (F4.6)")
    func savedWithoutStaleText() throws {
        var score = Self.score(with: Self.subitoP())
        _ = try SetDynamic(at: Self.slot(2), subtype: "f").apply(to: &score)
        let xml = try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(!xml.contains("subito"))
        #expect(xml.contains("<subtype>f</subtype>"))
    }
}
