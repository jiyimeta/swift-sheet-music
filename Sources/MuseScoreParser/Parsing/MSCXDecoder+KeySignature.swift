import Foundation

extension KeySignature {
    static func decode(_ node: XMLNode) throws -> KeySignature {
        // Modern mscx uses <concertKey>; older forms use <accidental>.
        if let text = node.first("concertKey")?.text, let key = Int(text) {
            return KeySignature(concertKey: key)
        }
        if let text = node.first("accidental")?.text, let key = Int(text) {
            return KeySignature(concertKey: key)
        }
        throw MuseScoreParserError.malformedScore(reason: "KeySig missing <concertKey>/<accidental>")
    }
}
