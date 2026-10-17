@testable import SheetMusicCore
import Testing

/// The text a tempo marking prints — derived in MuseScore's palette spelling, or authored — and MuseScore's own reading
/// of that text (`TempoText::updateTempo`, `engraving/dom/tempotext.cpp:260-318`), which decides what a number edit
/// does to its words.
@Suite("Tempo marking text")
struct TempoMarkingTextTests {
    private static let plain = RichTextFormat()

    private static func sym(_ name: String) -> PreservedTextMarkup.ContentItem {
        .element(PreservedTextMarkup.Element(name: "sym", content: [.characters(name)]))
    }

    private static func reading(_ content: [PreservedTextMarkup.ContentItem]) -> TempoTextEquation {
        TempoTextEquation(RichText(content: content))
    }

    // MARK: - The derived marking

    @Test("a quarter at 2 bps prints the quarter glyph and 120")
    func quarter() {
        #expect(Tempo(beatsPerSecond: 2).metronomeMarking
            == Tempo.MetronomeMarking(symbolNames: ["metNoteQuarterUp"], number: "120"))
    }

    @Test("a dotted beat prints a space and one dot per dot, and its number in that beat")
    func dotted() {
        let marking = Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1).metronomeMarking
        #expect(marking?.symbolNames == ["metNoteQuarterUp", "space", "metAugmentationDot"])
        #expect(marking?.number == "80")
        #expect(marking?.trailingText == " = 80")
    }

    @Test("the number prints to two decimals, an integral one without a point")
    func printedNumber() {
        #expect(Tempo.printedNumber(40.00002) == "40")
        #expect(Tempo.printedNumber(74.8) == "74.8")
        #expect(Tempo.printedNumber(74.800_000_01) == "74.8")
    }

    @Test("the number never traps: huge and non-finite values, tiny and negative ones")
    func printedNumberExtremes() {
        #expect(!Tempo.printedNumber(1e300).isEmpty)
        #expect(!Tempo.printedNumber(1e15).isEmpty)
        #expect(Tempo.printedNumber(.infinity).isEmpty)
        #expect(Tempo.printedNumber(-.infinity).isEmpty)
        #expect(Tempo.printedNumber(.nan).isEmpty)
        #expect(Tempo.printedNumber(0.004) == "0")
        #expect(Tempo.printedNumber(-74.8) == "-74.8")
        #expect(Tempo.printedNumber(-40.00002) == "-40")
    }

    @Test("a beat the decoder cannot read back prints as a quarter; a non-positive bps prints nothing")
    func fallbacks() {
        #expect(Tempo(beatsPerSecond: 2, beatNote: .sixtyFourth).metronomeMarking?.symbolNames == ["metNoteQuarterUp"])
        #expect(Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 3).metronomeMarking?.number == "120")
        #expect(Tempo(beatsPerSecond: 0).metronomeMarking == nil)
    }

    @Test("only the dotted rows MuseScore lists are printed: 2 dots on a whole, sixteenth or 32nd fall back")
    func dotRowsFollowMuseScore() {
        for beat in [NoteDuration.whole, .sixteenth, .thirtySecond] {
            let marking = Tempo(beatsPerSecond: 2, beatNote: beat, beatDots: 2).metronomeMarking
            #expect(marking == Tempo.MetronomeMarking(symbolNames: ["metNoteQuarterUp"], number: "120"))
        }
        #expect(Tempo(beatsPerSecond: 2, beatNote: .whole, beatDots: 1).metronomeMarking?.symbolNames
            == ["metNoteWhole", "space", "metAugmentationDot"])
        #expect(Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1).metronomeMarking?.symbolNames
            == ["metNoteQuarterUp", "space", "metAugmentationDot"])
        #expect(Tempo(beatsPerSecond: 2, beatNote: .eighth, beatDots: 2).metronomeMarking?.symbolNames
            == ["metNote8thUp", "space", "metAugmentationDot", "metAugmentationDot"])
    }

    // MARK: - What the marking displays

    @Test("a derived marking displays its glyph runs and the number")
    func derivedDisplay() {
        #expect(Tempo(beatsPerSecond: 2).displayedRichText.lines == [[
            .symbol(name: "metNoteQuarterUp", Self.plain), .text(" = 120", Self.plain),
        ]])
    }

    @Test("an authored plain text displays as written, one line per line break")
    func authoredPlainDisplay() {
        let tempo = Tempo(beatsPerSecond: 2.4, text: "Allegro\nmolto")
        #expect(tempo.displayedRichText.lines == [[.text("Allegro", Self.plain)], [.text("molto", Self.plain)]])
    }

    @Test("an authored formatted text displays its runs while current")
    func authoredRichDisplay() {
        let markup = PreservedTextMarkup(
            content: [.element(PreservedTextMarkup.Element(name: "b", content: [.characters("Lento")]))],
            derivedText: "Lento",
        )
        let tempo = Tempo(beatsPerSecond: 1, text: "Lento", preservedTextMarkup: markup)
        #expect(tempo.displayedRichText.lines == [[.text("Lento", RichTextFormat(bold: true))]])
    }

    @Test("the palette's own text is the derived marking; anything else is authored")
    func synthesizedMarkingRecognition() {
        let tempo = Tempo(beatsPerSecond: 2)
        let palette = PreservedTextMarkup(
            content: [Self.sym("metNoteQuarterUp"), .characters(" = 120")], derivedText: " = 120",
        )
        let withFont = PreservedTextMarkup(
            content: [
                Self.sym("metNoteQuarterUp"),
                .element(PreservedTextMarkup.Element(name: "font", attributes: ["face": "Edwin"])),
                .characters(" = 120"),
            ],
            derivedText: " = 120",
        )
        let otherNumber = PreservedTextMarkup(
            content: [Self.sym("metNoteQuarterUp"), .characters(" = 121")], derivedText: " = 121",
        )
        #expect(tempo.isSynthesizedMarking(palette))
        // Older MuseScore files carry the font element; it stays authored (preserved), by design.
        #expect(!tempo.isSynthesizedMarking(withFont))
        #expect(!tempo.isSynthesizedMarking(otherNumber))
    }

    @Test("a text that is exactly the derived marking stays derived")
    func derivedText() {
        var tempo = Tempo(beatsPerSecond: 2)
        let markup = PreservedTextMarkup(
            content: [
                .element(PreservedTextMarkup.Element(name: "sym", content: [.characters("metNoteQuarterUp")])),
                .characters(" = 120"),
            ],
            derivedText: " = 120",
        )
        tempo.adoptText(markup, plainText: " = 120")
        #expect(tempo.text == nil)
        #expect(tempo.preservedTextMarkup == nil)
    }

    @Test("any other text is authored and keeps its markup")
    func authoredText() {
        var tempo = Tempo(beatsPerSecond: 2)
        let markup = PreservedTextMarkup(
            content: [.element(PreservedTextMarkup.Element(name: "b", content: [.characters("Allegro")]))],
            derivedText: "Allegro",
        )
        tempo.adoptText(markup, plainText: "Allegro")
        #expect(tempo.text == "Allegro")
        #expect(tempo.preservedTextMarkup == markup)
    }

    // MARK: - MuseScore's reading of the words

    @Test("an equation alone is a whole-text metronome marking")
    func equationOnly() {
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = 120")])
            == .metronome(beatQuarters: 1, number: 120, isWholeText: true))
        #expect(Self.reading([
            Self.sym("metNoteQuarterUp"), Self.sym("space"), Self.sym("metAugmentationDot"), .characters(" = 80"),
        ]) == .metronome(beatQuarters: 1.5, number: 80, isWholeText: true))
    }

    @Test("words around the equation make it part of the text")
    func wordsAndEquation() {
        #expect(Self.reading([.characters("Allegro "), Self.sym("metNoteQuarterUp"), .characters(" = 144")])
            == .metronome(beatQuarters: 1, number: 144, isWholeText: false))
    }

    @Test("words alone, and a beat equal to a beat")
    func wordsAndRelative() {
        #expect(Self.reading([.characters("Allegro")]) == .words)
        #expect(Self.reading([.characters("a tempo")]) == .words)
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = "), Self.sym("metNote8thUp")]) == .relative)
    }

    @Test("MuseScore's normalization: ≈ and ~ read as =, ca. vanishes, a comma is a decimal point")
    func normalization() {
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" ≈ 72")])
            == .metronome(beatQuarters: 1, number: 72, isWholeText: true))
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = ca. 72")])
            == .metronome(beatQuarters: 1, number: 72, isWholeText: true))
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = 120,5")])
            == .metronome(beatQuarters: 1, number: 120.5, isWholeText: true))
    }

    @Test("a MuseScore 2/3 metronome character reads like the symbol")
    func legacyCodepoint() {
        let legacy = RichText(lines: [[
            .text("\u{ECA5}", RichTextFormat(face: "ScoreText")), .text(" = 60", RichTextFormat(bold: true)),
        ]])
        #expect(TempoTextEquation(legacy) == .metronome(beatQuarters: 1, number: 60, isWholeText: true))
    }

    @Test("an unknown symbol contributes nothing, as in MuseScore")
    func unknownSymbolIsDropped() {
        #expect(Self.reading([
            Self.sym("metNoteQuarterUp"), .characters(" "), Self.sym("bogus"), .characters(" = 80"),
        ]) == .metronome(beatQuarters: 1, number: 80, isWholeText: true))
    }

    @Test("whitespace is ASCII \\s over scalars: a combining mark does not fuse with its neighbor")
    func scalarsNotGraphemes() {
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = 80\u{0301}")])
            == .metronome(beatQuarters: 1, number: 80, isWholeText: false))
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters("\u{0301} = 80")]) == .words)
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters("\u{A0}= 80")]) == .words)
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters("\t=\u{0B}80\u{0C}\r")])
            == .metronome(beatQuarters: 1, number: 80, isWholeText: true))
    }

    @Test("a 400-digit number does not crash")
    func absurdNumber() {
        let digits = String(repeating: "9", count: 400)
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = \(digits)")]) != .relative)
    }

    @Test("an empty text is words; trailing words make the equation part of the text")
    func emptyAndTrailingWords() {
        #expect(TempoTextEquation(RichText(lines: [])) == .words)
        #expect(TempoTextEquation(RichText(lines: [[]])) == .words)
        #expect(Self.reading([Self.sym("metNoteQuarterUp"), .characters(" = 80 rit.")])
            == .metronome(beatQuarters: 1, number: 80, isWholeText: false))
    }

    @Test("MuseScore's table reads only stem-up notes, quarter patterns first")
    func patternTable() {
        #expect(Self.reading([Self.sym("metNoteQuarterDown"), .characters(" = 60")]) == .words)
        #expect(Self.reading([
            Self.sym("metNote8thUp"), .characters(" = 60 "), Self.sym("metNoteQuarterUp"), .characters(" = 120"),
        ]) == .metronome(beatQuarters: 1, number: 120, isWholeText: false))
    }
}
