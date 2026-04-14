import Foundation
import SheetMusicCore

extension Instrument {
    static func decode(_ node: XMLNode) throws -> Instrument {
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
        return Instrument(
            id: id,
            longName: node.first("longName")?.text,
            shortName: node.first("shortName")?.text,
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
