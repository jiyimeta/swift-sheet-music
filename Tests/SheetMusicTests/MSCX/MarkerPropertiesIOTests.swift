import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// A marker's and a jump's own properties, read where MuseScore writes them and written where MuseScore reads them
/// (`TRead::read(Marker*)`, `rw/read460/tread.cpp:1700-1726`; `TWrite::write(const Marker*)`, `twrite.cpp:2274-2282`).
@Suite("MSCX marker and jump properties")
struct MarkerPropertiesIOTests {
    private static func xml(_ node: XMLTreeNode) throws -> String {
        try #require(String(bytes: XMLTreeSerializer.serialize(node), encoding: .utf8))
    }

    private static func position(of tag: String, in xml: String) throws -> Int {
        let range = try #require(xml.range(of: tag))
        return xml.distance(from: xml.startIndex, to: range.lowerBound)
    }

    @Test("visible, offset, placement, autoplace, color, center-on-symbol and symbol size are read, not kept as markup")
    func decodes() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("marker-properties"))
        let bars = try #require(score.parts.first?.staves.first).measures
        try #require(bars.count == 5)
        let segno = try #require(bars[0].markers.first)
        #expect(segno.musicSymbolSize == 24 && segno.centersOnSymbol)
        #expect(segno.elementProperties == ElementProperties())
        let toCoda = try #require(bars[1].markers.first)
        #expect(!toCoda.elementProperties.visible)
        let jump = try #require(bars[2].jumps.first)
        #expect(jump.elementProperties.offset == ScoreOffset(x: -2, y: 0))
        #expect(jump.elementProperties.color == ScoreColor(red: 200, green: 0, blue: 0))
        let coda = try #require(bars[3].markers.first)
        #expect(coda.elementProperties.placement == .below && !coda.centersOnSymbol)
        let fine = try #require(bars[4].markers.first)
        #expect(fine.elementProperties.autoplace == false)
        #expect(fine.elementProperties.offset == ScoreOffset(x: 0, y: 1))
        let markup = bars.flatMap { $0.markers.flatMap(\.preservedMarkup) + $0.jumps.flatMap(\.preservedMarkup) }
        #expect(markup.isEmpty)
    }

    /// Color and symbol size go after `<style>`, which MuseScore applies as it reads it and which resets both
    /// (`ElementProperties.mscxTrailingChildren`; the 4.6.0–4.6.2 symbol-size bug `TRead::read(Marker*)` works around);
    /// `<markerType>` and `<markerCenterOnSymbol>` close the element, as MuseScore writes them.
    @Test("a marker's and a jump's properties are written where MuseScore reads them")
    func encodesInOrder() throws {
        let bar = try XMLTreeParser.parse(Data("""
        <Measure><Marker><style>Repeat Text Left</style><text><sym>coda</sym></text><label>codab</label>\
        <visible>0</visible><offset x="1" y="-2"/><placement>below</placement><autoplace>0</autoplace>\
        <color r="10" g="20" b="30" a="255"/><musicSymbolSize>24</musicSymbolSize><markerType>codab</markerType>\
        <markerCenterOnSymbol>0</markerCenterOnSymbol></Marker>\
        <Jump><text>D.C.</text><jumpTo>start</jumpTo><playUntil>end</playUntil><style>Repeat Text Right</style>\
        <color r="10" g="20" b="30" a="255"/><placement>below</placement></Jump><voice></voice></Measure>
        """.utf8), preservingMixedContentIn: ["text"])
        let measure = try Measure.decode(bar)
        let markerNode = try #require(measure.markers.first).encode()
        let marker = try Self.xml(markerNode)
        for tag in ["<visible>0</visible>", "<offset ", "<placement>below</placement>", "<autoplace>0</autoplace>"] {
            #expect(marker.contains(tag), "\(tag): \(marker)")
        }
        let tags = ["<style>", "<color ", "<musicSymbolSize>24", "<markerType>", "<markerCenterOnSymbol>0"]
        let order = try tags.map { try Self.position(of: $0, in: marker) }
        #expect(order == order.sorted(), "\(marker)")
        let jumpNode = try #require(measure.jumps.first).encode()
        let jump = try Self.xml(jumpNode)
        let style = try Self.position(of: "<style>", in: jump)
        let color = try Self.position(of: "<color ", in: jump)
        #expect(style < color && jump.contains("<placement>below</placement>"))
        let plain = try Self.xml(Marker(kind: .coda).encode())
        #expect(!plain.contains("<visible") && !plain.contains("<markerCenterOnSymbol"))
    }
}
