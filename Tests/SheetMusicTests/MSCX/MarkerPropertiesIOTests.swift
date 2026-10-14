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

    /// `<offset>` belongs to the repeat text styles, so a `<style>` read after it resets it in MuseScore
    /// (`TextBase::initTextStyleType`, `dom/textbase.cpp:3073-3100`): it is written after the preserved `<style>`.
    @Test("an offset is written after the preserved style and survives a round trip")
    func offsetFollowsStyle() throws {
        let bar = try XMLTreeParser.parse(Data("""
        <Measure><Marker><offset x="1.5" y="-2"/><style>Repeat Text Left</style><text>Fine</text><label>fine</label>\
        <markerType>fine</markerType></Marker>\
        <Jump><offset x="-3" y="1"/><text>D.C.</text><jumpTo>start</jumpTo><playUntil>end</playUntil>\
        <style>Repeat Text Right</style></Jump><voice></voice></Measure>
        """.utf8), preservingMixedContentIn: ["text"])
        let measure = try Measure.decode(bar)
        let marker = try #require(measure.markers.first)
        let jump = try #require(measure.jumps.first)
        #expect(marker.elementProperties.offset == ScoreOffset(x: 1.5, y: -2))
        #expect(jump.elementProperties.offset == ScoreOffset(x: -3, y: 1))
        let markerXML = try Self.xml(marker.encode())
        let jumpXML = try Self.xml(jump.encode())
        let markerStyle = try Self.position(of: "<style>", in: markerXML)
        let markerOffset = try Self.position(of: "<offset ", in: markerXML)
        let jumpStyle = try Self.position(of: "<style>", in: jumpXML)
        let jumpOffset = try Self.position(of: "<offset ", in: jumpXML)
        #expect(markerStyle < markerOffset && jumpStyle < jumpOffset)
        let reparsed = try XMLTreeParser.parse(Data("<Measure>\(markerXML)\(jumpXML)<voice></voice></Measure>".utf8))
        let again = try Measure.decode(reparsed)
        #expect(again.markers.first?.elementProperties.offset == marker.elementProperties.offset)
        #expect(again.jumps.first?.elementProperties.offset == jump.elementProperties.offset)
    }

    /// MuseScore applies `<markerType>` as it reads it, and a type whose side differs from the style read so far
    /// re-applies the other repeat style (`Marker::setMarkerType`, `dom/marker.cpp:86-106`), which resets the offset
    /// and the color read before it: a Fine read with `repeat_left`, or with no `<style>` at all, lost both when
    /// MuseScore reopened this library's save. Both follow the type.
    @Test("a marker's offset and color follow its type, which can re-apply the repeat style")
    func offsetAndColorFollowTheType() throws {
        var fine = Marker(kind: .fine)
        fine.elementProperties.offset = ScoreOffset(x: 0, y: 1)
        fine.elementProperties.color = ScoreColor(red: 200, green: 0, blue: 0)
        let xml = try Self.xml(fine.encode())
        let type = try Self.position(of: "<markerType>", in: xml)
        let offset = try Self.position(of: "<offset ", in: xml)
        let color = try Self.position(of: "<color ", in: xml)
        #expect(type < offset && type < color, "\(xml)")
    }

    /// Symbol size goes after `<style>`, which MuseScore applies as it reads it and which resets it (the 4.6.0–4.6.2
    /// symbol-size bug `TRead::read(Marker*)` works around); `<markerType>` follows, then the offset and color it
    /// could reset, and `<markerCenterOnSymbol>` closes the element, as MuseScore writes it.
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
        let tags = ["<style>", "<musicSymbolSize>24", "<markerType>", "<color ", "<markerCenterOnSymbol>0"]
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
