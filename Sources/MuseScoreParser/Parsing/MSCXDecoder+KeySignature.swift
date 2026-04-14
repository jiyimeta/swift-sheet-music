import Foundation

extension KeySignature {
    static func decode(_ node: XMLNode) throws -> KeySignature {
        guard let text = node.first("concertKey")?.text, let key = Int(text) else {
            throw MuseScoreParserError.malformedScore(reason: "KeySig missing <concertKey>")
        }
        return KeySignature(concertKey: key)
    }
}
