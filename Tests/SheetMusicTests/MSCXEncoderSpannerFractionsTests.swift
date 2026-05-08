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
}
