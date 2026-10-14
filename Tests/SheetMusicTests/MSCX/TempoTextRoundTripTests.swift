import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A `<Tempo>` keeps what MuseScore wrote: its text (authored, or derived when it is exactly the marking this library
/// prints), `<type>`, `<play>`, `<followText>` and the children nothing models — and saves them back in MuseScore's
/// order (`TWrite::write(const TempoText*)`, `rw/write/twrite.cpp:3163-3181`).
@Suite("Tempo text round trip")
struct TempoTextRoundTripTests {
    private static func fixture() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-texts"))
    }

    /// The tempo of 1-based measure `number`.
    private static func tempo(_ score: Score, measure number: Int) -> Tempo? {
        let lane = score.systemMeasures.values
        guard number - 1 < lane.count else { return nil }
        for positioned in lane[number - 1].elements.values {
            if case let .tempo(tempo) = positioned.element { return tempo }
        }
        return nil
    }

    private static func encoded(_ score: Score) throws -> String {
        let data = try MSCXEncoder.encode(score)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static func score(with tempo: Tempo) -> Score {
        var score = EditingFixtures.fourQuarterRests()
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(tempo)),
        ])]
        return score
    }

    @Test("MuseScore's palette markings decode derived; a muted one keeps its play flag")
    func canonicalTextIsDerived() throws {
        let score = try Self.fixture()
        let quarter = try #require(Self.tempo(score, measure: 1))
        #expect(quarter.text == nil)
        #expect(quarter.followText)
        #expect(quarter.beatsPerMinute.rounded() == 80)
        let muted = try #require(Self.tempo(score, measure: 7))
        #expect(muted.text == nil)
        #expect(!muted.playsBack)
        let dotted = try #require(Self.tempo(score, measure: 9))
        #expect(dotted.text == nil)
        #expect(dotted.beatNote == .quarter)
        #expect(dotted.beatDots == 1)
    }

    /// `<followText>` is read only when present (`tread.cpp:628-629`) and MuseScore's reader starts from
    /// `m_followText = false` (`tempotext.cpp:68`): an absent tag means off. Measure 4 ("Allegro", no tag) pins that.
    @Test("words, a tempo and tempo primo keep their text, type and follow flag")
    func wordsAndTypesAreKept() throws {
        let score = try Self.fixture()
        let aTempo = try #require(Self.tempo(score, measure: 3))
        #expect(aTempo.text == "a tempo")
        #expect(aTempo.textType == .aTempo)
        #expect(aTempo.followText)
        let allegro = try #require(Self.tempo(score, measure: 4))
        #expect(allegro.text == "Allegro")
        #expect(allegro.textType == .normal)
        #expect(!allegro.followText)
        #expect(allegro.beatsPerSecond == 2.4)
        let primo = try #require(Self.tempo(score, measure: 5))
        #expect(primo.text == "tempo primo")
        #expect(primo.textType == .tempoPrimo)
    }

    @Test("a modulation, words with an equation, and formatted words are authored, with their markup")
    func relativeAndMixedTextsAreAuthored() throws {
        let score = try Self.fixture()
        let modulation = try #require(Self.tempo(score, measure: 6))
        #expect(modulation.text == " = ")
        #expect(modulation.richText?.lines == [[
            .symbol(name: "metNoteQuarterUp", RichTextFormat()), .text(" = ", RichTextFormat()),
            .symbol(name: "metNote8thUp", RichTextFormat()),
        ]])
        let allegro = try #require(Self.tempo(score, measure: 8))
        #expect(allegro.text == "Allegro  = 144")
        #expect(allegro.richText != nil)
        let lento = try #require(Self.tempo(score, measure: 11))
        #expect(lento.richText?.lines.first?.first == .text("Lento ", RichTextFormat(bold: true)))
    }

    @Test("a marking without text opens hidden, as MuseScore opens it")
    func noTextIsHidden() throws {
        let hidden = try #require(Self.tempo(Self.fixture(), measure: 10))
        #expect(!hidden.visible)
        #expect(hidden.text == nil)
        #expect(hidden.beatsPerSecond == 2.5)
        #expect(!hidden.followText)
    }

    /// A one-measure score whose only `<Tempo>` holds `children`.
    private static func inlineTempo(_ children: String) throws -> Tempo {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument id="piano"><longName>Piano</longName><trackName>Piano</trackName>
        <Channel><program value="0"/></Channel></Instrument></Part>
        <Staff id="1"><Measure><voice>
        <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
        <Tempo>\(children)</Tempo>
        <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
        </voice></Measure></Staff></Score></museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        return try #require(tempo(score, measure: 1))
    }

    /// `TConv::fromXml(e.readAsciiText(), Constants::DEFAULT_TEMPO)` (`tread.cpp:627`): 120 bpm, i.e. 2 bps, when the
    /// value does not parse — and when the tag is absent, since the reader starts from the default.
    @Test("a garbage or missing <tempo> falls back to 2 beats per second", arguments: [
        "<tempo>fast</tempo><text>Allegro</text>", "<text>Allegro</text>",
    ])
    func unparsableTempoFallsBackToDefault(children: String) throws {
        let tempo = try Self.inlineTempo(children)
        #expect(tempo.beatsPerSecond == 2)
        #expect(tempo.text == "Allegro")
    }

    /// An unrecognised `<type>` is `e.unknown()` (`tread.cpp:638-640`), leaving the default `NORMAL`.
    @Test("an unknown <type> reads as normal")
    func unknownTypeReadsAsNormal() throws {
        let tempo = try Self.inlineTempo("<tempo>2</tempo><type>bogus</type><text>Allegro</text>")
        #expect(tempo.textType == .normal)
        #expect(tempo.text == "Allegro")
    }

    /// MuseScore parses with `parse_default` (`xmlstreamreader.cpp:109`), which creates no whitespace-only PCDATA
    /// node, so `readXml()` returns "" and the sanity check at `tread.cpp:648` hides the marking, as for `<text/>`.
    @Test("a whitespace-only <text> opens hidden, like an empty one")
    func whitespaceTextOpensHidden() throws {
        let tempo = try Self.inlineTempo("<tempo>2</tempo><text>   </text>")
        #expect(!tempo.visible)
        #expect(tempo.text == nil)
    }

    @Test("children nothing models are kept and written back")
    func unmodeledChildrenAreKept() throws {
        let score = try Self.fixture()
        let allegro = try #require(Self.tempo(score, measure: 8))
        #expect(allegro.preservedMarkup.map(\.name) == ["musicSymbolSize"])
        #expect(try Self.encoded(score).contains("<musicSymbolSize>18</musicSymbolSize>"))
    }

    @Test("a marking made here reopens derived and saves byte for byte", arguments: [
        Tempo(beatsPerSecond: 2), Tempo(beatsPerSecond: 0.666667),
        Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1),
        Tempo(beatsPerSecond: 1.5, beatNote: .half), Tempo(beatsPerSecond: 4, beatNote: .eighth, beatDots: 1),
        Tempo(beatsPerSecond: 2, beatNote: .sixtyFourth),
    ])
    func derivedMarkingRoundTripsDerived(tempo: Tempo) throws {
        let first = try MSCXEncoder.encode(Self.score(with: tempo))
        let reopened = try MSCXParser.parse(first)
        let decoded = try #require(Self.tempo(reopened, measure: 1))
        #expect(decoded.text == nil)
        #expect(decoded.preservedTextMarkup == nil)
        #expect(decoded.followText)
        #expect(try MSCXEncoder.encode(reopened) == first)
    }

    @Test("authored text, type and play are written back verbatim")
    func authoredTextIsWrittenBackVerbatim() throws {
        let xml = try Self.encoded(Self.fixture())
        #expect(xml.contains("<text>Allegro <sym>metNoteQuarterUp</sym> = 144</text>"))
        #expect(xml.contains("<text><b>Lento </b><sym>metNoteQuarterUp</sym> = 50</text>"))
        #expect(xml.contains("<text><sym>metNoteQuarterUp</sym> = <sym>metNote8thUp</sym></text>"))
        #expect(xml.contains("<type>aTempo</type>"))
        #expect(xml.contains("<type>tempoPrimo</type>"))
        #expect(xml.contains("<play>0</play>"))
        #expect(xml.contains("<text>Allegro</text>"))
    }

    @Test("children are written in MuseScore's order: play, tempo, followText, type, …, text")
    func writeOrderFollowsMuseScore() throws {
        let score = try Self.fixture()
        let names = { (number: Int) -> [String] in
            Self.tempo(score, measure: number)?.encode(eid: .invalid).children.map(\.name) ?? []
        }
        #expect(names(7) == ["play", "tempo", "followText", "text"])
        #expect(names(3) == ["tempo", "followText", "type", "text"])
        #expect(names(4) == ["tempo", "text"])
        #expect(names(8) == ["tempo", "followText", "musicSymbolSize", "text"])
        #expect(names(10) == ["tempo", "visible", "text"])
    }

    @Test("an edited text is written plain; its stale markup is dropped")
    func editedTextDropsStaleMarkup() throws {
        var lento = try #require(Self.tempo(Self.fixture(), measure: 11))
        lento.text = "Adagio"
        let text = lento.encode(eid: .invalid).first("text")
        #expect(text?.text == "Adagio")
        #expect(text?.children.isEmpty == true)
    }

    @Test("a MuseScore 3 marking's ScoreText character and fonts survive a save")
    func legacyScoreTextMarkupSurvives() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("testVoltaTemp"))
        let tempos = score.systemMeasures.values.flatMap(\.elements.values).compactMap { positioned -> Tempo? in
            if case let .tempo(tempo) = positioned.element { return tempo }
            return nil
        }
        let tempo = try #require(tempos.first)
        #expect(tempo.text == "\u{ECA5} = 180")
        let xml = try Self.encoded(score)
        #expect(xml.contains("<font face=\"ScoreText\"/>\u{ECA5}<b><font face=\"FreeSerif\"/> = 180</b>"))
    }
}
