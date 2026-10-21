import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

/// The ends of MuseScore's duration range this package reads since 4.16: a full-measure rest in a bar of two whole
/// notes or more, which MuseScore draws as the breve rest; a breve in a tuplet; and the 512th and 1024th, which made a
/// MuseScore file fail to import (`mscx.chord.invalidDurationType`).
struct LongAndShortDurationTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func mscx(sigN: Int, sigD: Int, body: String) -> Data {
        Data("""
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure><voice><TimeSig><sigN>\(sigN)</sigN><sigD>\(sigD)</sigD></TimeSig>\(body)</voice></Measure>
            </Staff>
          </Score>
        </museScore>
        """.utf8)
    }

    @Test func aFullMeasureRestDrawsAsTheBreveRestOnceTheBarHoldsTwoWholeNotes() {
        #expect(LayoutEngine.measureRestBase(in: Fraction(numerator: 2, denominator: 1)) == .breve)
        #expect(LayoutEngine.measureRestBase(in: Fraction(numerator: 3, denominator: 1)) == .breve)
        #expect(LayoutEngine.measureRestBase(in: Fraction(numerator: 3, denominator: 2)) == .whole)
        #expect(LayoutEngine.measureRestBase(in: Fraction(numerator: 1, denominator: 1)) == .whole)
        #expect(RestGlyph.codepoint(duration: .measure, hasLegerLine: false, measureRestsAreBreves: true)
            == SMuFLCodepoint.restDoubleWhole)
        #expect(RestGlyph.codepoint(duration: .measure, hasLegerLine: false, measureRestsAreBreves: false)
            == SMuFLCodepoint.restWhole)
        // A typed rest is what it says it is, whatever the bar.
        #expect(RestGlyph.codepoint(duration: .half, hasLegerLine: false, measureRestsAreBreves: true)
            == SMuFLCodepoint.restHalf)
    }

    @Test func aFourTwoBarsMeasureRestIsLaidOutAsABreveRest() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let rest = "<Rest><durationType>measure</durationType><duration>2/1</duration></Rest>"
        let long = try MSCXParser.parse(Self.mscx(sigN: 4, sigD: 2, body: rest))
        let common = try MSCXParser.parse(Self.mscx(sigN: 4, sigD: 4, body: rest))
        func measure(_ score: Score) throws -> LayoutMeasure {
            let doc = LayoutEngine.layout(score: score, options: .init(wrapToViewWidth: false), availableWidth: 900)
            return try #require(doc.systems.first?.measures.first)
        }
        #expect(try measure(long).measureRestsAreBreves)
        #expect(try !measure(common).measureRestsAreBreves)
        // The element keeps `.measure`: the cursor and the range box read it as the bar-filling rest.
        let durations = try measure(long).elements.compactMap { element -> NoteDuration? in
            if case let .rest(duration, _, _, _, _) = element { duration } else { nil }
        }
        #expect(durations == [.measure])
    }

    @Test func aBreveInATupletIsEngravedAsABreve() {
        // Three breves in the time of two: each is 2 × 2/3 = 4/3 of a whole note.
        #expect(DurationInterpretation.splitNote(.fraction(Fraction(numerator: 4, denominator: 3))) == (.breve, 0))
        // A whole-note triplet is still a whole.
        #expect(DurationInterpretation.splitNote(.fraction(Fraction(numerator: 2, denominator: 3))) == (.whole, 0))
    }

    @Test func the512thAndThe1024thImportAndWriteBack() throws {
        let body = "<Chord><durationType>512th</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>"
            + "<Chord><durationType>1024th</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>"
            + "<Rest><durationType>1024th</durationType></Rest>"
            + "<Rest><dots>1</dots><durationType>512th</durationType></Rest>"
            + "<Rest><durationType>128th</durationType></Rest>"
        // 15/1024 in a 1/64 bar: underfull, which the reader keeps as written, as MuseScore does.
        let score = try MSCXParser.parse(Self.mscx(sigN: 1, sigD: 64, body: body))
        let durations = score.parts[0].staves[0].measures[0].voices[0].elements.compactMap { element -> NoteDuration? in
            if case let .chord(chord) = element { chord.duration } else { nil }
        }
        #expect(Array(durations.prefix(3)) == [.fiveHundredTwelfth, .oneThousandTwentyFourth, .oneThousandTwentyFourth])
        #expect(BeamGrouping.level(of: .fiveHundredTwelfth) == 7)
        #expect(BeamGrouping.level(of: .oneThousandTwentyFourth) == 8)

        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        let squeezed = xml.filter { !$0.isWhitespace }
        #expect(squeezed.contains("<durationType>512th</durationType>"))
        #expect(squeezed.contains("<durationType>1024th</durationType>"))
        #expect(squeezed.contains("<dots>1</dots><durationType>512th</durationType>"))
    }
}
