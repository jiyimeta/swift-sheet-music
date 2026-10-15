@testable import SheetMusicCore
import Testing

@Suite("Spanner line labels")
struct SpannerLineLabelsTests {
    private static let ped = "<sym>keyboardPedalPed</sym>"
    private static let parens =
        "<sym>keyboardPedalParensLeft</sym><sym>keyboardPedalPed</sym><sym>keyboardPedalParensRight</sym>"
    private static let star = "<sym>keyboardPedalUp</sym>"

    private static func pedal(
        _ line: Spanner.LineProperties? = Spanner.LineProperties(), begin: String? = nil,
    ) -> Spanner {
        var spanner = Spanner(kind: .pedal, rawType: "Pedal", beginText: begin)
        spanner.lineProperties = line
        return spanner
    }

    @Test("a bare pedal is Ped and a line, no end glyph")
    func barePedalIsPedAndLine() {
        let labels = Self.pedal().lineLabels
        #expect(labels.begin == Self.ped)
        #expect(labels.continuation == Self.parens)
        #expect(labels.end == nil)
        // A payload that sets nothing decodes to `nil`; it reads exactly like an all-default `LineProperties()`.
        #expect(Self.pedal(nil).lineLabels == Self.pedal().lineLabels)
    }

    @Test("the asterisk pedal ends in the rosette")
    func asteriskPedalHasRosetteAndNoLine() {
        let line = Spanner.LineProperties(endHook: .rosette, lineVisible: false)
        #expect(Self.pedal(line).lineLabels.end == Self.star)
        #expect(Self.pedal(line).lineLabels.begin == Self.ped)
    }

    @Test("a begin hook silences the pedal's own begin and continue texts")
    func hooksDropTheTexts() {
        let line = Spanner.LineProperties(beginHook: .hook90, endHook: .hook90)
        let labels = Self.pedal(line).lineLabels
        #expect(labels.begin == nil)
        #expect(labels.continuation == nil)
        #expect(labels.end == nil)
    }

    @Test("an authored empty text removes the styled default")
    func emptyAuthoredTextRemovesTheDefault() {
        // MuseScore writes `<beginText></beginText>` for this (`vtest/scores/line-dashed.mscx:261`); it draws nothing.
        #expect(Self.pedal(begin: "").lineLabels.begin?.isEmpty == true)
        #expect(Self.pedal(begin: "").lineLabels.continuation == Self.parens)
    }

    @Test("authored text wins")
    func authoredWins() {
        #expect(Self.pedal(begin: "Sost.").lineLabels.begin == "Sost.")
    }

    @Test("hairpin lines carry cresc./dim. and their continuations; wedges carry nothing")
    func hairpins() {
        func spanner(_ subtype: Spanner.HairpinPayload.Subtype, begin: String? = nil) -> Spanner {
            Spanner(kind: .hairpin, rawType: "HairPin", beginText: begin, hairpin: .init(subtype: subtype))
        }
        #expect(spanner(.crescLine).lineLabels.begin == "cresc.")
        #expect(spanner(.crescLine).lineLabels.continuation == "(cresc.)")
        #expect(spanner(.dimLine).lineLabels.begin == "dim.")
        #expect(spanner(.dimLine).lineLabels.continuation == "(dim.)")
        #expect(spanner(.crescLine, begin: "poco a poco cresc.").lineLabels.begin == "poco a poco cresc.")
        #expect(spanner(.crescendo).lineLabels == Spanner.LineLabels())
        #expect(spanner(.decrescendo, begin: "dim.").lineLabels.begin == "dim.")
    }

    @Test("palm mute, let ring and the guitar lines default as MuseScore's styles do")
    func guitarDefaults() {
        func labels(_ kind: Spanner.Kind, _ line: Spanner.ChordTextLine? = nil) -> Spanner.LineLabels {
            var spanner = Spanner(kind: kind, rawType: line?.rawValue ?? kind.rawValue)
            spanner.chordTextLine = line
            return spanner.lineLabels
        }
        #expect(labels(.palmMute).begin == "P.M.")
        #expect(labels(.palmMute).continuation == "P.M.")
        #expect(labels(.letRing).begin == "let ring")
        #expect(labels(.chordTextLine, .rasgueado).begin == "rasg")
        #expect(labels(.chordTextLine, .pickScrape).begin == "P.S.")
        #expect(labels(.chordTextLine, .whammyBar).begin == "w/bar")
        #expect(labels(.chordTextLine, .harmonicMark) == Spanner.LineLabels())
        #expect(labels(.textLine) == Spanner.LineLabels())
    }

    @Test("end and continue texts the file authored are used for every kind")
    func authoredContinueAndEnd() {
        var spanner = Spanner(
            kind: .textLine, rawType: "TextLine", beginText: "a", continueText: "(a)", endText: "b",
        )
        #expect(spanner.lineLabels == Spanner.LineLabels(begin: "a", continuation: "(a)", end: "b"))
        spanner.kind = .volta
        spanner.beginText = "Last time"
        #expect(spanner.lineLabels.begin == "Last time")
    }
}
