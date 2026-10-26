import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// A two-note tremolo's chords are written twice as long as they last (`Chord.isWrittenDoubled`), as MuseScore writes
/// them: `<durationType>half</durationType><duration>1/4</duration>`. The decoder used to take the written half as the
/// length, so MuseScore's own pair of halves sounded a whole and overfilled its bar.
@Suite("Two-note tremolo written values")
struct TwoNoteTremoloWrittenValueTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let note = "<Note><pitch>69</pitch><tpc>17</tpc></Note>"

    private static func voice(_ body: String) throws -> Voice {
        try Voice.decode(XMLTreeParser.parse(Data("<voice>\(body)</voice>".utf8)))
    }

    private static let museScorePair = """
    <Chord><durationType>half</durationType><duration>1/4</duration>\(note)\
    <TremoloTwoChord><subtype>c8</subtype></TremoloTwoChord></Chord>
    <Chord><durationType>half</durationType><duration>1/4</duration>\(note)</Chord>
    <Chord><durationType>half</durationType>\(note)</Chord>
    """

    private static func chords(_ voice: Voice) -> [Chord] {
        voice.elements.values.compactMap { element in
            if case let .chord(chord) = element { chord } else { nil }
        }
    }

    @Test("MuseScore's pair lasts a quarter each, is drawn as halves, and fills its bar")
    func museScorePairDecodes() throws {
        let chords = try Self.chords(Self.voice(Self.museScorePair))
        #expect(chords.map(\.duration) == [.quarter, .quarter, .half])
        #expect(chords.map(\.isWrittenDoubled) == [true, true, false])
        #expect(chords.map(\.drawnDuration) == [.half, .half, .half])
        let total = chords.reduce(Fraction(numerator: 0, denominator: 1)) { $0 + $1.duration.asFraction }
        #expect(total == Fraction(numerator: 1, denominator: 1))
    }

    @Test("a save writes the pair's written half and its quarter length back")
    func pairEncodes() throws {
        let encoded = try Self.voice(Self.museScorePair).encode()
        let written = encoded.children.filter { $0.name == "Chord" }.map { chord in
            [chord.first("durationType")?.text ?? "", chord.first("duration")?.text ?? ""]
        }
        #expect(written == [["half", "1/4"], ["half", "1/4"], ["half", ""]])
    }

    @Test("a <duration> that is not half the written value stays as it was read")
    func otherDurationsStayPreserved() throws {
        let chords = try Self.chords(Self.voice(
            "<Chord><durationType>quarter</durationType><duration>1/16</duration>\(Self.note)</Chord>",
        ))
        #expect(chords.map(\.duration) == [.quarter])
        #expect(chords.map(\.isWrittenDoubled) == [false])
        #expect(chords.first?.preservedMarkup.contains { $0.name == "duration" } == true)
    }

    @Test("the layout draws the pair as halves")
    @available(macOS 15.0, iOS 16.0, *)
    func layoutDrawsTheWrittenValue() throws {
        let voice = try Self.voice(Self.museScorePair)
        let score = Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: [voice])])],
        )])
        let doc = LayoutArticulationTests.laidOut(score)
        let drawn = (doc.systems.first?.measures.first?.elements ?? []).compactMap { element -> NoteDuration? in
            if case let .chord(_, duration, _, _, _, _, _, _, _, _, _) = element { duration } else { nil }
        }
        #expect(drawn == [.half, .half, .half])
    }
}
