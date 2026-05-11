import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

struct HairpinEncoderTests {
    @Test func nilHairpinEmitsBareElement() throws {
        let s = Spanner(kind: .hairpin, rawType: "HairPin")
        let hp = try #require(s.encode().first("HairPin"))
        #expect(hp.children.isEmpty)
    }

    @Test func crescendoWithVeloChange() throws {
        let s = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            hairpin: .init(subtype: .crescendo, veloChange: 20),
        )
        let hp = try #require(s.encode().first("HairPin"))
        #expect(hp.first("subtype")?.text == "0")
        #expect(hp.first("veloChange")?.text == "20")
        // .normal omitted
        #expect(hp.children.map(\.name).contains("veloChangeMethod") == false)
    }

    @Test func decrescendoEaseInOut() throws {
        let s = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            hairpin: .init(subtype: .decrescendo, veloChangeMethod: .easeInOut),
        )
        let hp = try #require(s.encode().first("HairPin"))
        #expect(hp.first("subtype")?.text == "1")
        #expect(hp.children.map(\.name).contains("veloChange") == false)
        #expect(hp.first("veloChangeMethod")?.text == "ease-in-out")
    }

    @Test func roundTripPreservesPayload() throws {
        let original = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 1,
            hairpin: .init(subtype: .crescendo, veloChange: 15, veloChangeMethod: .easeIn),
        )
        let encoded = original.encode()
        let xml = XMLTreeSerializer.serialize(encoded)
        let reparsed = try XMLTreeParser.parse(xml)
        let decoded = try Spanner.decode(reparsed)
        #expect(decoded.kind == .hairpin)
        #expect(decoded.hairpin?.subtype == .crescendo)
        #expect(decoded.hairpin?.veloChange == 15)
        #expect(decoded.hairpin?.veloChangeMethod == .easeIn)
        #expect(decoded.nextMeasuresOffset == 1)
    }
}
