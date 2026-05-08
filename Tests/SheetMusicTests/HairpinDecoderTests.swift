import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct HairpinDecoderTests {
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

    @Test func veloChangeZeroIsNormalisedToNil() throws {
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
}
