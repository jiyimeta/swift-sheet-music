import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

struct VibratoDecodeTests {
    private func decode(_ xml: String) throws -> Spanner {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Spanner.decode(node)
    }

    @Test func decodesGuitarVibratoSubtype() throws {
        let xml = """
        <Spanner type="Vibrato">\
        <Vibrato><subtype>guitarVibrato</subtype></Vibrato>\
        <next><location><measures>1</measures></location></next>\
        </Spanner>
        """
        let sp = try decode(xml)
        #expect(sp.kind == .vibrato)
        #expect(sp.vibrato?.type == .guitarVibrato)
    }

    @Test func decodesGuitarVibratoWideSubtype() throws {
        let xml = """
        <Spanner type="Vibrato">\
        <Vibrato><subtype>guitarVibratoWide</subtype></Vibrato>\
        <next><location><measures>1</measures></location></next>\
        </Spanner>
        """
        let sp = try decode(xml)
        #expect(sp.kind == .vibrato)
        #expect(sp.vibrato?.type == .guitarVibratoWide)
    }

    @Test func decodesSawtoothSubtype() throws {
        let xml = """
        <Spanner type="Vibrato">\
        <Vibrato><subtype>vibratoSawtooth</subtype></Vibrato>\
        <next><location><measures>1</measures></location></next>\
        </Spanner>
        """
        let sp = try decode(xml)
        #expect(sp.vibrato?.type == .sawtooth)
    }

    @Test func decodesSawtoothWideSubtype() throws {
        let xml = """
        <Spanner type="Vibrato">\
        <Vibrato><subtype>vibratoSawtoothWide</subtype></Vibrato>\
        <next><location><measures>1</measures></location></next>\
        </Spanner>
        """
        let sp = try decode(xml)
        #expect(sp.vibrato?.type == .sawtoothWide)
    }

    @Test func unknownSubtypeDefaultsAndWarns() throws {
        let collector = MSCXDiagnosticCollector()
        let xml = """
        <Spanner type="Vibrato">\
        <Vibrato><subtype>bogus</subtype></Vibrato>\
        <next><location><measures>1</measures></location></next>\
        </Spanner>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let sp = try MSCXParserContext.$collector.withValue(collector) {
            try Spanner.decode(node)
        }
        #expect(sp.vibrato?.type == .guitarVibrato)
        #expect(collector.entries.contains { $0.code == "mscx.vibrato.unknownSubtype" })
    }

    @Test func nonVibratoSpannerHasNilVibrato() throws {
        let xml = #"<Spanner type="Slur"><Slur/></Spanner>"#
        let sp = try decode(xml)
        #expect(sp.kind == .slur)
        #expect(sp.vibrato == nil)
    }
}
