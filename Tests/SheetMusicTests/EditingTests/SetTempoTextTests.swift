import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// `SetTempo` writes a marking's text and `<play>`, reads back what plays, and edits a number the way the marking's
/// words call for (spec 2026-10-14 §5.6): an equation alone becomes derived, words around an equation get the new
/// number written in — glyph and formatting kept — and words alone keep their words.
@Suite("SetTempo — text, play and the number-edit rule")
struct SetTempoTextTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// The measure rest of `tempo-texts`' 1-based measure `number` (measure 1 carries a time signature first).
    private static func anchor(measure number: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: number - 1, voiceIndex: 0, elementIndex: number == 1 ? 1 : 0)
    }

    private static func fixture() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-texts"))
    }

    private static func tempo(_ score: Score, measure number: Int) throws -> Tempo {
        try #require(SetTempo.tempo(at: anchor(measure: number), in: score))
    }

    /// One tempo at the score's first beat, written by `SetTempo` from `marking`.
    private static func edited(_ tempo: Tempo, to marking: SetTempo.Marking) throws -> Tempo {
        var score = EditingFixtures.fourQuarterRests()
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(tempo)),
        ])]
        let anchor = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        _ = try SetTempo(anchor: anchor, marking: marking).apply(to: &score)
        return try #require(SetTempo.tempo(at: anchor, in: score))
    }

    @Test("an equation alone becomes derived when its number changes")
    func equationOnlyTextBecomesDerived() throws {
        let legacy = Tempo(beatsPerSecond: 3, text: "\u{ECA5} = 180", followText: true)
        let edited = try Self.edited(legacy, to: SetTempo.Marking(beatsPerSecond: 2))
        #expect(edited.text == nil)
        #expect(edited.preservedTextMarkup == nil)
        #expect(edited.followText)
    }

    @Test("words around an equation get the new number in the text and in the markup, glyph kept")
    func wordsAndEquationRewriteKeepsGlyph() throws {
        var score = try Self.fixture()
        _ = try SetTempo(anchor: Self.anchor(measure: 8), marking: SetTempo.Marking(beatsPerSecond: 2.2))
            .apply(to: &score)
        let edited = try Self.tempo(score, measure: 8)
        #expect(edited.text == "Allegro  = 132")
        #expect(edited.richText?.lines == [[
            .text("Allegro ", RichTextFormat()), .symbol(name: "metNoteQuarterUp", RichTextFormat()),
            .text(" = 132", RichTextFormat()),
        ]])
        let data = try MSCXEncoder.encode(score)
        let xml = try #require(String(bytes: data, encoding: .utf8))
        #expect(xml.contains("<text>Allegro <sym>metNoteQuarterUp</sym> = 132</text>"))
    }

    /// The interim bug this task closes: `write` changed the number and kept an authored text, so editing
    /// "Allegro ♩ = 144" saved the old "144" beside the new `<tempo>`.
    @Test("an authored 'Allegro ♩ = 144' no longer keeps the old 144 beside the new tempo")
    func authoredWordsFollowTheNewNumber() throws {
        let authored = Tempo(beatsPerSecond: 2.4, text: "Allegro \u{ECA5} = 144")
        let edited = try Self.edited(authored, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.beatsPerSecond == 2.2)
        #expect(edited.text == "Allegro \u{ECA5} = 132")
        #expect(edited.text?.contains("144") == false)
    }

    @Test("a number the markup cannot reach rewrites the words and drops only the stale formatting")
    func unreachableNumberKeepsWords() throws {
        let markup = PreservedTextMarkup(
            content: [
                .characters("Allegro "),
                .element(PreservedTextMarkup.Element(name: "sym", content: [.characters("metNoteQuarterUp")])),
                .characters(" = "),
                .element(PreservedTextMarkup.Element(name: "b", content: [.characters("144")])),
            ],
            derivedText: "Allegro  = 144",
        )
        let tempo = Tempo(beatsPerSecond: 2.4, text: "Allegro  = 144", preservedTextMarkup: markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == "Allegro  = 132")
        #expect(edited.preservedTextMarkup == nil)
        #expect(edited.beatsPerSecond == 2.2)
    }

    @Test("words alone keep their words; a tempo becomes an ordinary marking with them")
    func wordsAloneAndATempo() throws {
        var score = try Self.fixture()
        _ = try SetTempo(anchor: Self.anchor(measure: 4), marking: SetTempo.Marking(beatsPerSecond: 2.6))
            .apply(to: &score)
        _ = try SetTempo(anchor: Self.anchor(measure: 3), marking: SetTempo.Marking(beatsPerSecond: 1.5))
            .apply(to: &score)
        let allegro = try Self.tempo(score, measure: 4)
        #expect(allegro.text == "Allegro")
        #expect(allegro.beatsPerSecond == 2.6)
        let aTempo = try Self.tempo(score, measure: 3)
        #expect(aTempo.text == "a tempo")
        #expect(aTempo.textType == .normal)
        #expect(aTempo.beatsPerSecond == 1.5)
    }

    @Test("a set text and a play flag are written as given")
    func setTextAndPlay() throws {
        let edited = try Self.edited(
            Tempo(beatsPerSecond: 2),
            to: SetTempo.Marking(beatsPerSecond: 2, text: .set("Andante"), playsBack: false),
        )
        #expect(edited.text == "Andante")
        #expect(!edited.playsBack)
        let derived = try Self.edited(edited, to: SetTempo.Marking(beatsPerSecond: 2, text: .derive, playsBack: true))
        #expect(derived.text == nil)
        #expect(derived.playsBack)
    }

    @Test("current reads what plays: an a tempo its reinstated tempo, a muted marking its play flag")
    func currentIsWhatPlays() throws {
        let score = try Self.fixture()
        let aTempo = try #require(SetTempo.current(at: Self.anchor(measure: 3), in: score))
        #expect(aTempo == SetTempo.Marking(beatsPerSecond: 1.333333))
        let muted = try #require(SetTempo.current(at: Self.anchor(measure: 7), in: score))
        #expect(muted.playsBack == false)
        let plain = try #require(SetTempo.current(at: Self.anchor(measure: 4), in: score))
        #expect(plain == SetTempo.Marking(beatsPerSecond: 2.4))
        #expect(SetTempo.inForce(at: Self.anchor(measure: 2), in: score) == SetTempo.Marking(beatsPerSecond: 1.333333))
    }

    @Test("the number is read and written in the marking's own beat")
    func beatsPerMinuteIsInTheBeat() {
        var marking = SetTempo.Marking(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1)
        #expect(marking.beatsPerMinute == 80)
        marking.beatsPerMinute = 60
        #expect(marking.beatsPerSecond == 1.5)
    }
}
