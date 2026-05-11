import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for the `<next><location><fractions>` element
/// that MuseScore emits when a spanner ends mid-measure. Phase 1/2
/// silently dropped this; Phase 3 preserves it via
/// `Spanner.nextFractionsOffset`.
@Suite("MSCXEncoder spanner fractions")
struct MSCXEncoderSpannerFractionsTests {
    /// Decode a single `<Spanner>` element from an inline XML literal.
    private func decodeSpanner(_ xml: String) throws -> Spanner {
        let bytes = Data(xml.utf8)
        let root = try XMLTreeParser.parse(bytes)
        return try Spanner.decode(#require(root.first("Spanner")))
    }

    @Test("Decoder reads <fractions> alongside <measures>")
    func decodeFractionsAndMeasures() throws {
        let xml = """
        <root>
          <Spanner type="HairPin">
            <HairPin/>
            <next>
              <location>
                <fractions>1/4</fractions>
                <measures>1</measures>
              </location>
            </next>
          </Spanner>
        </root>
        """
        let spanner = try decodeSpanner(xml)
        #expect(spanner.nextFractionsOffset == Fraction(numerator: 1, denominator: 4))
        #expect(spanner.nextMeasuresOffset == 1)
    }

    @Test("Decoder leaves nextFractionsOffset nil when <fractions> absent")
    func decodeMeasuresOnlyKeepsFractionsNil() throws {
        let xml = """
        <root>
          <Spanner type="Volta">
            <Volta><endings>1</endings></Volta>
            <next>
              <location>
                <measures>2</measures>
              </location>
            </next>
          </Spanner>
        </root>
        """
        let spanner = try decodeSpanner(xml)
        #expect(spanner.nextFractionsOffset == nil)
        #expect(spanner.nextMeasuresOffset == 2)
    }

    /// Round-trip: encode → reparse → compare.
    private func roundTrip(_ spanner: Spanner) throws -> Spanner {
        let xml = spanner.encode()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Spanner.decode(#require(reparsed.first("Spanner")))
    }

    @Test("Encoder emits <fractions> before <measures>")
    func encoderEmitsFractionsBeforeMeasures() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 1,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )
        let xml = spanner.encode()
        let location = try #require(
            xml.first("next")?.first("location"),
        )
        let names = location.children.map(\.name)
        #expect(names == ["fractions", "measures"])
        #expect(location.first("fractions")?.text == "1/4")
        #expect(location.first("measures")?.text == "1")
    }

    @Test("Round-trip preserves nextFractionsOffset alongside measures")
    func roundTripPreservesBothOffsets() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 2,
            nextFractionsOffset: Fraction(numerator: 3, denominator: 8),
        )
        let decoded = try roundTrip(spanner)
        #expect(decoded.nextMeasuresOffset == 2)
        #expect(decoded.nextFractionsOffset == Fraction(numerator: 3, denominator: 8))
    }

    @Test("Round-trip preserves nextFractionsOffset with measures = 0")
    func roundTripFractionsOnly() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 2),
        )
        let decoded = try roundTrip(spanner)
        #expect(decoded.nextMeasuresOffset == 0)
        #expect(decoded.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
    }

    @Test("Round-trip preserves measures-only spanner (fractions stays nil)")
    func roundTripMeasuresOnly() throws {
        let spanner = Spanner(
            kind: .volta,
            rawType: "Volta",
            nextMeasuresOffset: 1,
            voltaEndings: [1],
        )
        let decoded = try roundTrip(spanner)
        #expect(decoded.nextMeasuresOffset == 1)
        #expect(decoded.nextFractionsOffset == nil)
    }
}
