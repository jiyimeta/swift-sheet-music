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
        let unreachable = Self.unreachable(prefix: "Allegro ", number: "144")
        let tempo = Tempo(beatsPerSecond: 2.4, text: unreachable.text, preservedTextMarkup: unreachable.markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == "Allegro  = 132")
        #expect(edited.preservedTextMarkup == nil)
        #expect(edited.beatsPerSecond == 2.2)
    }

    @Test("a number split across runs is rewritten whole, and the run that held its first digit keeps the formatting")
    func numberSplitAcrossRunsKeepsFormatting() throws {
        let content: [Item] = [.characters("Allegro "), Self.quarter, .characters(" = 1"), Self.bold("44")]
        let markup = PreservedTextMarkup(content: content, derivedText: "Allegro  = 144")
        let tempo = Tempo(beatsPerSecond: 2.4, text: "Allegro  = 144", preservedTextMarkup: markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == "Allegro  = 132")
        // The `<b>` that held only the rest of the old number is removed, not kept empty.
        let expected: [Item] = [.characters("Allegro "), Self.quarter, .characters(" = 132")]
        #expect(edited.preservedTextMarkup?.content == expected)
        #expect(edited.preservedTextMarkup?.derivedText == "Allegro  = 132")
    }

    @Test("MuseScore's ca. prefix is kept where it stands, and the equation is still found")
    func approximatePrefixIsKept() throws {
        let cases: [(String, String)] = [
            ("Allegro \u{ECA5} ca. = 120", "Allegro \u{ECA5} ca. = 132"),
            ("Allegro \u{ECA5} = ca. 120", "Allegro \u{ECA5} = ca. 132"),
            ("x = 3 \u{ECA5} approx. = c. 120", "x = 3 \u{ECA5} approx. = c. 132"),
        ]
        for (input, expected) in cases {
            let edited = try Self.edited(
                Tempo(beatsPerSecond: 2, text: input), to: SetTempo.Marking(beatsPerSecond: 2.2),
            )
            #expect(edited.text == expected)
        }
    }

    @Test("an unreachable first equation stops the markup search; a later equation of the same beat stays")
    func laterEquationIsNotRewrittenInsteadOfAnUnreachableFirst() throws {
        let group = Item.element(PreservedTextMarkup.Element(name: "b", content: [Self.quarter, .characters(" =")]))
        let content: [Item] = [
            .characters("Allegro "), group, .characters(" 144 and "), Self.quarter, .characters(" = 120"),
        ]
        let text = "Allegro  = 144 and  = 120"
        let markup = PreservedTextMarkup(content: content, derivedText: text)
        let tempo = Tempo(beatsPerSecond: 2.4, text: text, preservedTextMarkup: markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == "Allegro  = 132 and  = 120")
        #expect(edited.preservedTextMarkup == nil)
    }

    @Test("a quarter, a typed space and a dot written as symbols is one dotted beat: the number is counted in it")
    func splitGlyphIsStillLocated() throws {
        let dot = Self.sym("metAugmentationDot")
        let content: [Item] = [.characters("Allegro "), Self.quarter, .characters(" "), dot, .characters(" = 120")]
        let text = "Allegro   = 120"
        let markup = PreservedTextMarkup(content: content, derivedText: text)
        let tempo = Tempo(beatsPerSecond: 2, text: text, preservedTextMarkup: markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        // The classifier reads a dotted quarter (1.5 quarters); 2.2 × 60 / 1.5 is 88. The words are kept, not derived.
        #expect(edited.text == "Allegro   = 88")
        #expect(edited.followText)
        // Whatever markup is left must describe the rewritten text (the cross-check drops one that would not).
        if let kept = edited.preservedTextMarkup {
            #expect(RichText(markup: kept).plainText == edited.text)
        }
    }

    private typealias Item = PreservedTextMarkup.ContentItem

    /// A marking whose glyph sits inside a `<b>` with its equals sign, and whose number is outside it: the classifier
    /// reads "prefix♩ = number", but no single element list holds all of it, so the markup cannot be rewritten.
    private static func unreachable(prefix: String, number: String) -> (markup: PreservedTextMarkup, text: String) {
        let group = Item.element(PreservedTextMarkup.Element(name: "b", content: [quarter, .characters(" =")]))
        let text = "\(prefix) = \(number)"
        let content: [Item] = [.characters(prefix), group, .characters(" \(number)")]
        return (PreservedTextMarkup(content: content, derivedText: text), text)
    }

    private static func sym(_ name: String) -> Item {
        .element(PreservedTextMarkup.Element(name: "sym", content: [.characters(name)]))
    }

    private static let quarter = sym("metNoteQuarterUp")

    private static func bold(_ text: String) -> Item {
        .element(PreservedTextMarkup.Element(name: "b", content: [.characters(text)]))
    }

    @Test("a number behind another tag is rewritten in the text and in the markup, and an earlier equals sign is left")
    func numberBehindATagIsReached() throws {
        let content: [Item] = [.characters("x = 3 Allegro "), Self.quarter, .characters(" = "), Self.bold("120")]
        let markup = PreservedTextMarkup(content: content, derivedText: "x = 3 Allegro  = 120")
        let tempo = Tempo(beatsPerSecond: 2, text: "x = 3 Allegro  = 120", preservedTextMarkup: markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == "x = 3 Allegro  = 132")
        let expected: [Item] = [.characters("x = 3 Allegro "), Self.quarter, .characters(" = "), Self.bold("132")]
        #expect(edited.preservedTextMarkup?.content == expected)
        #expect(edited.preservedTextMarkup?.derivedText == "x = 3 Allegro  = 132")
    }

    @Test("a number the markup cannot reach is found by the same equation in the text, not by the first equals sign")
    func unreachableNumberDoesNotTouchAnEarlierEquals() throws {
        let unreachable = Self.unreachable(prefix: "x = 3 Allegro ", number: "120")
        let tempo = Tempo(beatsPerSecond: 2, text: unreachable.text, preservedTextMarkup: unreachable.markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == "x = 3 Allegro  = 132")
        #expect(edited.preservedTextMarkup == nil)
    }

    @Test("when the markup is dropped, a host beat change counts the number in the beat the text had")
    func droppedMarkupKeepsTheTextsBeat() throws {
        let unreachable = Self.unreachable(prefix: "Allegro ", number: "144")
        let tempo = Tempo(beatsPerSecond: 2.4, text: unreachable.text, preservedTextMarkup: unreachable.markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2, beatNote: .eighth))
        // The markup is dropped because the number is outside the element that holds the glyph. The glyph lived only
        // there, so the text has none to rewrite: the equation stays true in the quarter the text had.
        #expect(edited.text == "Allegro  = 132")
        #expect(edited.preservedTextMarkup == nil)
        #expect(edited.beatNote == .eighth)
    }

    @Test("with two equations, the one the classifier reads is the one rewritten")
    func firstOfTheClassifiedBeat() throws {
        let content: [Item] = [
            Self.sym("metNote8thUp"), .characters(" = 60 and "), Self.sym("metNoteQuarterUp"), .characters(" = 120"),
        ]
        let markup = PreservedTextMarkup(content: content, derivedText: " = 60 and  = 120")
        let tempo = Tempo(beatsPerSecond: 2, text: " = 60 and  = 120", preservedTextMarkup: markup)
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
        #expect(edited.text == " = 60 and  = 132")
        let expected: [Item] = [
            Self.sym("metNote8thUp"), .characters(" = 60 and "), Self.sym("metNoteQuarterUp"), .characters(" = 132"),
        ]
        #expect(edited.preservedTextMarkup?.content == expected)
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

    @Test("a number edit is counted in the beat the text prints; a host beat change rewrites the glyph too")
    func numberIsCountedInTheTextsBeat() throws {
        let dotted = Tempo(beatsPerSecond: 1, beatDots: 1, text: "Allegro \u{ECA5}\u{ECB7} = 40")
        // The beat stays a dotted quarter: only the number is written, counted in that beat (1.2 × 60 / 1.5).
        let sameBeat = try Self.edited(dotted, to: SetTempo.Marking(beatsPerSecond: 1.2, beatDots: 1))
        #expect(sameBeat.text == "Allegro \u{ECA5}\u{ECB7} = 48")
        // The host changes the beat to a plain quarter: the glyph follows and the number is counted in the new beat.
        let changedBeat = try Self.edited(dotted, to: SetTempo.Marking(beatsPerSecond: 1))
        #expect(changedBeat.text == "Allegro \u{ECA5} = 60")
        #expect(changedBeat.beatDots == 0)
    }

    @Test("a decimal tempo prints the way the derived text prints decimals")
    func decimalNumber() throws {
        let tempo = Tempo(beatsPerSecond: 2, text: "Allegro \u{ECA5} = 120")
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 72.5 / 60))
        #expect(edited.text == "Allegro \u{ECA5} = \(Tempo.printedNumber(72.5))")
        #expect(edited.text == "Allegro \u{ECA5} = 72.5")
    }

    @Test("a host beat change rewrites a markup glyph and counts the number in the new beat")
    func beatChangeRewritesMarkupGlyph() throws {
        var score = try Self.fixture()
        let marking = SetTempo.Marking(beatsPerSecond: 2.4, beatNote: .eighth)
        _ = try SetTempo(anchor: Self.anchor(measure: 8), marking: marking).apply(to: &score)
        let edited = try Self.tempo(score, measure: 8)
        #expect(edited.text == "Allegro  = 288")
        let data = try MSCXEncoder.encode(score)
        let xml = try #require(String(bytes: data, encoding: .utf8))
        #expect(xml.contains("<text>Allegro <sym>metNote8thUp</sym> = 288</text>"))
    }

    @Test("the equation the classification matched is the one rewritten")
    func anchoredOnTheEquation() throws {
        let cases: [(String, String)] = [
            ("2 Allegro \u{ECA5} = 120", "2 Allegro \u{ECA5} = 132"),
            ("x = 3 Allegro \u{ECA5} = 120", "x = 3 Allegro \u{ECA5} = 132"),
            ("(\u{ECA5} = 120)", "(\u{ECA5} = 132)"),
            ("\u{ECA5} = 60–70", "\u{ECA5} = 132–70"),
        ]
        for (input, expected) in cases {
            let tempo = Tempo(beatsPerSecond: 2, text: input)
            let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2))
            #expect(edited.text == expected)
        }
    }

    @Test("muting a following a tempo through current keeps its type, number and text")
    func mutingAnATempoKeepsIt() throws {
        var score = try Self.fixture()
        let anchor = Self.anchor(measure: 3)
        var marking = try #require(SetTempo.current(at: anchor, in: score))
        marking.playsBack = false
        _ = try SetTempo(anchor: anchor, marking: marking).apply(to: &score)
        let muted = try Self.tempo(score, measure: 3)
        #expect(muted.textType == .aTempo)
        #expect(muted.beatsPerSecond == 2)
        #expect(muted.text == "a tempo")
        #expect(!muted.playsBack)
        // `current` of the muted marking is the map's tempo with the play flag, as it is when unmuted.
        var expected = try #require(SetTempo.inForce(at: anchor, in: score))
        expected.playsBack = false
        #expect(SetTempo.current(at: anchor, in: score) == expected)
    }

    @Test("a stamped playsBack-only toggle replays as such after an earlier tempo changed; an unstamped one does not")
    func stampedToggleSurvivesAReplay() throws {
        let sender = try Self.fixture()
        let anchor = Self.anchor(measure: 3)
        var toggle = try #require(SetTempo.current(at: anchor, in: sender))
        toggle.playsBack = false
        let stamped = SetTempo.stamped(toggle, at: anchor, in: sender)
        #expect(stamped.numberEdit == false)

        // The receiver's earlier tempo moved before the replay, so `current` there reports another number.
        var stamping = try Self.fixture()
        _ = try SetTempo(anchor: Self.anchor(measure: 1), marking: SetTempo.Marking(beatsPerSecond: 1))
            .apply(to: &stamping)
        var replayed = stamping
        _ = try SetTempo(anchor: anchor, marking: stamped).apply(to: &replayed)
        let kept = try Self.tempo(replayed, measure: 3)
        #expect(kept.textType == .aTempo)
        #expect(kept.beatsPerSecond == 2)
        #expect(kept.text == "a tempo")
        #expect(!kept.playsBack)

        // Legacy: no stamp, so the receiver infers a number edit from its own `current`.
        var legacy = stamping
        _ = try SetTempo(anchor: anchor, marking: toggle).apply(to: &legacy)
        #expect(try Self.tempo(legacy, measure: 3).textType == .normal)
    }

    @Test("a stamped number edit is applied even when it equals what the receiver reports")
    func stampedNumberEditIsHonored() throws {
        let tempo = Tempo(beatsPerSecond: 2, text: "Allegro \u{ECA5} = 120")
        let edited = try Self.edited(tempo, to: SetTempo.Marking(beatsPerSecond: 2.2, numberEdit: true))
        #expect(edited.text == "Allegro \u{ECA5} = 132")
    }

    @Test("undoing a successful markup rewrite restores the markup and the file bytes")
    func undoRestoresARewrittenMarkup() throws {
        var score = try Self.fixture()
        let before = try MSCXEncoder.encode(score)
        let original = try Self.tempo(score, measure: 8)
        let anchor = Self.anchor(measure: 8)
        let inverse = try SetTempo(anchor: anchor, marking: SetTempo.Marking(beatsPerSecond: 2.2)).apply(to: &score)
        let changed = try Self.tempo(score, measure: 8)
        #expect(changed.text == "Allegro  = 132")
        #expect(changed.preservedTextMarkup != nil)
        #expect(changed.preservedTextMarkup != original.preservedTextMarkup)
        _ = try inverse.apply(to: &score)
        let restored = try Self.tempo(score, measure: 8)
        #expect(restored.text == original.text)
        #expect(restored.preservedTextMarkup == original.preservedTextMarkup)
        #expect(try MSCXEncoder.encode(score) == before)
    }

    @Test("undo restores the text, markup, follow flag, play flag and type a rewrite changed")
    func undoRestoresEverything() throws {
        let unreachable = Self.unreachable(prefix: "Allegro ", number: "144")
        let markup = unreachable.markup
        let original = Tempo(
            beatsPerSecond: 2.4, text: unreachable.text, preservedTextMarkup: markup,
            followText: true, textType: .aTempo, playsBack: false,
        )
        var score = EditingFixtures.fourQuarterRests()
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(original)),
        ])]
        let anchor = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let marking = SetTempo.Marking(beatsPerSecond: 2.2, playsBack: true)
        let inverse = try SetTempo(anchor: anchor, marking: marking).apply(to: &score)
        let changed = try #require(SetTempo.tempo(at: anchor, in: score))
        #expect(changed.text == "Allegro  = 132")
        #expect(changed.preservedTextMarkup == nil)
        #expect(changed.textType == .normal)
        #expect(changed.playsBack)
        _ = try inverse.apply(to: &score)
        let restored = try #require(SetTempo.tempo(at: anchor, in: score))
        #expect(restored.text == "Allegro  = 144")
        #expect(restored.preservedTextMarkup == markup)
        #expect(restored.followText)
        #expect(!restored.playsBack)
        #expect(restored.textType == .aTempo)
        #expect(restored.beatsPerSecond == 2.4)
    }

    @Test("the number is read and written in the marking's own beat")
    func beatsPerMinuteIsInTheBeat() {
        var marking = SetTempo.Marking(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1)
        #expect(marking.beatsPerMinute == 80)
        marking.beatsPerMinute = 60
        #expect(marking.beatsPerSecond == 1.5)
    }
}
