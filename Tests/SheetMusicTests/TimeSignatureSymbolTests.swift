#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import SheetMusicMusicXML
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's CoreGraphics shims also export `CGFloat`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGFloat` here would
    /// collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Common time, cut time, and the two rarer cut signs: the `<subtype>` MuseScore writes on a `<TimeSig>`,
/// modeled as `TimeSignatureSymbol` and drawn as one glyph instead of two rows of digits.
@Suite("Time signature symbols")
struct TimeSignatureSymbolTests {
    private static func pianoTemplate(measures: Int) -> BlankScoreTemplate {
        BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            measureCount: measures,
        )
    }

    // MARK: - Model

    @Test("a signature is drawn as its numbers unless it says otherwise")
    func defaultsToNumeric() {
        #expect(TimeSignature(numerator: 4, denominator: 4).symbol == .numeric)
    }

    @Test("the raw values are MuseScore's TimeSigType integers")
    func rawValuesMatchMuseScore() {
        #expect(TimeSignatureSymbol.numeric.rawValue == 0)
        #expect(TimeSignatureSymbol.common.rawValue == 1)
        #expect(TimeSignatureSymbol.cutCommon.rawValue == 2)
        #expect(TimeSignatureSymbol.cutBach.rawValue == 3)
        #expect(TimeSignatureSymbol.cutTriple.rawValue == 4)
    }

    @Test("each symbol names the meter it stands for")
    func conventionalMeters() throws {
        #expect(TimeSignatureSymbol.numeric.conventionalMeter == nil)
        let expected: [(TimeSignatureSymbol, Int, Int)] = [
            (.common, 4, 4), (.cutCommon, 2, 2), (.cutBach, 2, 2), (.cutTriple, 9, 8),
        ]
        for (symbol, n, d) in expected {
            let meter = try #require(symbol.conventionalMeter)
            #expect(meter == (n, d))
        }
    }

    @Test("the symbol is part of a signature's identity")
    func symbolParticipatesInEquality() {
        #expect(
            TimeSignature(numerator: 4, denominator: 4, symbol: .common)
                != TimeSignature(numerator: 4, denominator: 4),
        )
    }

    // MARK: - MSCX

    /// One bar whose opening time signature is `signature`.
    private static func score(declaring signature: TimeSignature) throws -> Score {
        var score = Score.blank(pianoTemplate(measures: 1))
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        let index = try #require(elements.firstIndex { if case .timeSignature = $0 { true } else { false } })
        score.parts[0].staves[0].measures[0].voices[0].elements[index] = .timeSignature(signature)
        return score
    }

    /// The signature the first bar declares. Found by scanning rather than by index: the encoder omits a
    /// C-major `<KeySig>`, so an element's position is not stable across a round trip.
    private static func declaredSignature(in score: Score) throws -> TimeSignature {
        try #require(score.parts[0].staves[0].measures[0].voices[0].elements.compactMap { element in
            if case let .timeSignature(t) = element { t } else { nil }
        }.first)
    }

    @Test("every symbol survives an mscx round trip")
    func symbolRoundTripsThroughMSCX() throws {
        let cases: [(TimeSignatureSymbol, Int, Int)] = [
            (.common, 4, 4), (.cutCommon, 2, 2), (.cutBach, 2, 2), (.cutTriple, 9, 8),
        ]
        for (symbol, n, d) in cases {
            let score = try Self.score(
                declaring: TimeSignature(numerator: n, denominator: d, symbol: symbol),
            )
            let data = try MSCXEncoder.encode(score)
            let xml = try #require(String(data: data, encoding: .utf8))
            #expect(xml.contains("<subtype>\(symbol.rawValue)</subtype>"))

            let decoded = try Self.declaredSignature(in: MSCXParser.parse(data))
            #expect(decoded.symbol == symbol)
            #expect(decoded.numerator == n)
            #expect(decoded.denominator == d)
        }
    }

    @Test("a numeric signature emits no <subtype>, keeping MuseScore-written files byte-stable")
    func numericEmitsNoSubtype() throws {
        let score = Score.blank(Self.pianoTemplate(measures: 1))
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(!xml.contains("<subtype>"))
    }

    @Test("<subtype> precedes <sigN>, as MuseScore writes it")
    func subtypePrecedesSigN() throws {
        let score = try Self.score(
            declaring: TimeSignature(numerator: 4, denominator: 4, symbol: .common),
        )
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        let subtype = try #require(xml.range(of: "<subtype>"))
        let sigN = try #require(xml.range(of: "<sigN>"))
        #expect(subtype.lowerBound < sigN.lowerBound)
    }

    @Test("an unrecognized <subtype> falls back to the numbers, with a diagnostic")
    func unknownSubtypeWarns() throws {
        let score = try Self.score(
            declaring: TimeSignature(numerator: 4, denominator: 4, symbol: .common),
        )
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        // 17 is not a `TimeSigType`. MuseScore never writes it; a hand-edited or future file could.
        let damaged = xml.replacingOccurrences(of: "<subtype>1</subtype>", with: "<subtype>17</subtype>")
        #expect(damaged != xml)

        let result = try MSCXParser.parseWithDiagnostics(Data(damaged.utf8))
        let decoded = try Self.declaredSignature(in: result.score)
        #expect(decoded.symbol == .numeric)
        #expect(decoded.numerator == 4)
        #expect(result.diagnostics.contains { $0.code == "mscx.timeSig.unknownSubtype" })
    }

    // MARK: - MusicXML

    @Test(
        "MusicXML <time symbol=…> maps onto the two symbols the format has",
        arguments: [("common", TimeSignatureSymbol.common), ("cut", .cutCommon), ("single-number", .numeric)],
    )
    func musicXMLTimeSymbol(attribute: String, expected: TimeSignatureSymbol) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="3.1">
          <part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
          <part id="P1"><measure number="1">
            <attributes>
              <divisions>1</divisions>
              <time symbol="\(attribute)"><beats>4</beats><beat-type>4</beat-type></time>
            </attributes>
            <note><rest/><duration>4</duration><type>whole</type></note>
          </measure></part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        let signature = try #require(elements.compactMap { element -> TimeSignature? in
            if case let .timeSignature(t) = element { t } else { nil }
        }.first)
        #expect(signature.symbol == expected)
        #expect(signature.numerator == 4)
    }

    // MARK: - Geometry

    @Test("a symbol maps to its SMuFL glyph; the numbers map to none")
    func symbolCodepoints() {
        #expect(TimeSignatureLayout.symbolCodepoint(.numeric) == nil)
        #expect(TimeSignatureLayout.symbolCodepoint(.common) == 0xE08A)
        #expect(TimeSignatureLayout.symbolCodepoint(.cutCommon) == 0xE08B)
        #expect(TimeSignatureLayout.symbolCodepoint(.cutBach) == 0xEC85)
        #expect(TimeSignatureLayout.symbolCodepoint(.cutTriple) == 0xEC86)
    }

    @Test("a symbol reserves one glyph's width, never two digits'")
    func symbolInkWidth() {
        let sp: CGFloat = 6
        let common = TimeSignatureLayout.inkWidth(
            numerator: 4, denominator: 4, symbol: .common, sp: sp,
        )
        #expect(common == TimeSignatureLayout.symbolWidth(sp: sp))
        // "12/8" as numbers is two digit strides wide; as a symbol it would not be.
        let numeric = TimeSignatureLayout.inkWidth(
            numerator: 12, denominator: 8, symbol: .numeric, sp: sp,
        )
        #expect(numeric > common)
    }

    @Test("a symbol sits on the staff middle, between the two digit rows")
    func symbolSitsOnTheMiddle() {
        let sp: CGFloat = 6
        #expect(TimeSignatureLayout.symbolDy(sp: sp) == 0)
        #expect(TimeSignatureLayout.numeratorDy(sp: sp) < 0)
        #expect(TimeSignatureLayout.denominatorDy(sp: sp) > 0)
    }
}
