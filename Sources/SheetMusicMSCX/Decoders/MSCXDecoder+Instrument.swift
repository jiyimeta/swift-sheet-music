import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Instrument {
    static func decode(_ node: XMLTreeNode) throws -> Instrument {
        // Both `<Instrument id="...">` and `<Instrument><instrumentId>...` forms exist;
        // some scores omit both — fall back to "" rather than failing.
        let id = node.attributes["id"] ?? node.first("instrumentId")?.text ?? ""
        let articulations = try node.all("Articulation").map { try InstrumentArticulation.decode($0) }
        let channelNodes = node.all("Channel")
        let channels: [InstrumentChannel]
        if channelNodes.isEmpty {
            channels = [InstrumentChannel()]
        } else {
            channels = try channelNodes.map { try InstrumentChannel.decode($0) }
        }
        // MuseScore 5.x wraps longName/shortName inside <InstrumentLabel>;
        // MuseScore 4.x has them as direct children. Accept either.
        let label = node.first("InstrumentLabel")
        let longName = label?.first("longName")?.text ?? node.first("longName")?.text
        let shortName = label?.first("shortName")?.text ?? node.first("shortName")?.text
        return Instrument(
            id: id,
            longName: longName,
            shortName: shortName,
            trackName: node.first("trackName")?.text,
            minPitchPlayable: node.first("minPitchP").flatMap { Int($0.text) },
            maxPitchPlayable: node.first("maxPitchP").flatMap { Int($0.text) },
            minPitchAmateur: node.first("minPitchA").flatMap { Int($0.text) },
            maxPitchAmateur: node.first("maxPitchA").flatMap { Int($0.text) },
            articulations: articulations,
            channels: channels
        )
    }
}
