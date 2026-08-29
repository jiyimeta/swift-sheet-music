import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

struct HairpinDecoderTests {
    private func decode(_ xml: String) throws -> Spanner {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Spanner.decode(node)
    }

    @Test func crescendoMinimalPayload() throws {
        let s = try decode(#"<Spanner type="HairPin"><HairPin/></Spanner>"#)
        #expect(s.kind == .hairpin)
        #expect(s.hairpin?.subtype == .crescendo)
        #expect(s.hairpin?.veloChange == nil)
        #expect(s.hairpin?.veloChangeMethod == .normal)
    }

    @Test func decrescendoExplicitSubtype() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><subtype>1</subtype></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.subtype == .decrescendo)
    }

    @Test func veloChangeZeroIsNormalizedToNil() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChange>0</veloChange></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChange == nil)
    }

    @Test func veloChangePositive() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChange>20</veloChange></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChange == 20)
    }

    @Test func veloChangeMethodEaseIn() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChangeMethod>ease-in</veloChangeMethod></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChangeMethod == .easeIn)
    }

    @Test func unknownMethodFallsBackToNormal() throws {
        let s = try decode(#"""
        <Spanner type="HairPin"><HairPin><veloChangeMethod>quintic</veloChangeMethod></HairPin></Spanner>
        """#)
        #expect(s.hairpin?.veloChangeMethod == .normal)
    }

    @Test func nonHairpinHasNilHairpin() throws {
        let s = try decode(#"<Spanner type="Slur"><Slur/></Spanner>"#)
        #expect(s.kind == .slur)
        #expect(s.hairpin == nil)
    }

    // MARK: - Payload model

    @Test func defaultSpannerHasNilHairpin() {
        let s = Spanner(kind: .hairpin, rawType: "HairPin")
        #expect(s.hairpin == nil)
    }

    @Test func payloadEqualityRespectsAllFields() {
        let a = Spanner.HairpinPayload(
            subtype: .crescendo,
            veloChange: 20,
            veloChangeMethod: .normal,
        )
        let b = Spanner.HairpinPayload(
            subtype: .crescendo,
            veloChange: 20,
            veloChangeMethod: .normal,
        )
        let c = Spanner.HairpinPayload(
            subtype: .decrescendo,
            veloChange: 20,
            veloChangeMethod: .normal,
        )
        #expect(a == b)
        #expect(a != c)
    }

    @Test func veloChangeMethodFromXMLString() {
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "normal") == .normal)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-in") == .easeIn)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-out") == .easeOut)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-in-out") == .easeInOut)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "exponential") == .exponential)
    }
}
