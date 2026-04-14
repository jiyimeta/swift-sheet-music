import Foundation

extension Instrument {
    static func decode(_ node: XMLNode) throws -> Instrument {
        guard let id = node.attributes["id"] ?? node.first("instrumentId")?.text else {
            throw MuseScoreParserError.malformedScore(reason: "Instrument missing id")
        }
        let articulations = try node.all("Articulation").map { try InstrumentArticulation.decode($0) }
        guard let channelNode = node.first("Channel") else {
            throw MuseScoreParserError.malformedScore(reason: "Instrument missing <Channel>")
        }
        let channel = try InstrumentChannel.decode(channelNode)
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
            channel: channel
        )
    }
}
