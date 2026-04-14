import Foundation

extension Part {
    static func decode(_ node: XMLNode) throws -> Part {
        guard let id = node.attributes["id"] else {
            throw MuseScoreParserError.malformedScore(reason: "Part missing id")
        }
        let staffDecls = try node.all("Staff").map { try StaffDeclaration.decode($0) }
        guard let instrNode = node.first("Instrument") else {
            throw MuseScoreParserError.malformedScore(reason: "Part missing <Instrument>")
        }
        let instrument = try Instrument.decode(instrNode)
        return Part(
            id: id,
            trackName: node.first("trackName")?.text,
            instrument: instrument,
            staffDeclarations: staffDecls
        )
    }
}
