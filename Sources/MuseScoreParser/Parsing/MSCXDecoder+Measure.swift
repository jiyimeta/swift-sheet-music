import Foundation

extension Measure {
    static func decode(_ node: XMLNode) throws -> Measure {
        let voiceNodes = node.all("voice")
        guard !voiceNodes.isEmpty else {
            throw MuseScoreParserError.malformedScore(reason: "Measure has no <voice>")
        }
        let voices = try voiceNodes.map { try Voice.decode($0) }
        return Measure(voices: voices)
    }
}
