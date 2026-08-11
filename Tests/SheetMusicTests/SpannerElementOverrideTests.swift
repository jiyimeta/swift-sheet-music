import Foundation
import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// MuseScore writes a spanner's per-element property overrides inside
/// the payload child: `<placement>` whenever the user flipped the
/// element off its styled side (`TWrite::writeItemProperties`,
/// twrite.cpp:578), and `<numbersOnly>` for an ottava
/// (`TWrite::write(const Ottava*)`, twrite.cpp:2445). The decoder read
/// neither, so an authored override silently lost to the style default.
@Suite("Spanner element overrides")
struct SpannerElementOverrideTests {
    private func spanner(_ xml: String) throws -> Spanner {
        try Spanner.decode(XMLTreeParser.parse(Data(xml.utf8)))
    }

    private func wrap(_ type: String, _ payload: String) -> String {
        """
        <Spanner type="\(type)">\(payload)
        <next><location><measures>1</measures></location></next></Spanner>
        """
    }

    // MARK: - placement

    @Test func placementIsDecodedForAnySpannerKind() throws {
        for (type, payload) in [
            ("Ottava", "<Ottava><subtype>8va</subtype>PLACEMENT</Ottava>"),
            ("HairPin", "<HairPin><subtype>0</subtype>PLACEMENT</HairPin>"),
            ("Trill", "<Trill><subtype>trill</subtype>PLACEMENT</Trill>"),
            ("Pedal", "<Pedal>PLACEMENT</Pedal>"),
        ] {
            let below = try spanner(wrap(
                type, payload.replacingOccurrences(
                    of: "PLACEMENT", with: "<placement>below</placement>",
                ),
            ))
            #expect(below.placement == .below)
            let above = try spanner(wrap(
                type, payload.replacingOccurrences(
                    of: "PLACEMENT", with: "<placement>above</placement>",
                ),
            ))
            #expect(above.placement == .above)
        }
    }

    @Test func anAbsentPlacementStaysNil() throws {
        let sp = try spanner(wrap(
            "Ottava", "<Ottava><subtype>8va</subtype></Ottava>",
        ))
        #expect(sp.placement == nil)
    }

    @Test func anUnknownPlacementValueIsIgnored() throws {
        let sp = try spanner(wrap(
            "Ottava",
            "<Ottava><subtype>8va</subtype><placement>sideways</placement></Ottava>",
        ))
        #expect(sp.placement == nil)
    }

    @Test func placementRoundTripsThroughTheEncoder() throws {
        let original = try spanner(wrap(
            "HairPin",
            "<HairPin><subtype>0</subtype><placement>above</placement></HairPin>",
        ))
        #expect(try Spanner.decode(original.encode()).placement == .above)
    }

    // MARK: - ottava numbersOnly

    @Test func ottavaNumbersOnlyOverrideIsDecoded() throws {
        let off = try spanner(wrap(
            "Ottava",
            "<Ottava><subtype>8va</subtype><numbersOnly>0</numbersOnly></Ottava>",
        ))
        #expect(off.ottava?.numbersOnly == false)
        let on = try spanner(wrap(
            "Ottava",
            "<Ottava><subtype>8va</subtype><numbersOnly>1</numbersOnly></Ottava>",
        ))
        #expect(on.ottava?.numbersOnly == true)
    }

    @Test func anAbsentNumbersOnlyInheritsTheStyle() throws {
        let sp = try spanner(wrap(
            "Ottava", "<Ottava><subtype>8va</subtype></Ottava>",
        ))
        #expect(sp.ottava?.numbersOnly == nil)
    }

    @Test func numbersOnlyRoundTripsThroughTheEncoder() throws {
        let original = try spanner(wrap(
            "Ottava",
            "<Ottava><subtype>15mb</subtype><numbersOnly>0</numbersOnly></Ottava>",
        ))
        let reparsed = try Spanner.decode(original.encode())
        #expect(reparsed.ottava?.numbersOnly == false)
        #expect(reparsed.ottava?.subtype == .fifteenMB)
    }
}
