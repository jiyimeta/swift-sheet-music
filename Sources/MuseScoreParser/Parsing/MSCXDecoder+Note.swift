import Foundation

extension Note {
    static func decode(_ node: XMLNode) throws -> Note {
        guard let pitchText = node.first("pitch")?.text, let pitch = Int(pitchText) else {
            throw MuseScoreParserError.malformedScore(reason: "Note missing <pitch>")
        }
        guard let tpcText = node.first("tpc")?.text, let tpc = Int(tpcText) else {
            throw MuseScoreParserError.malformedScore(reason: "Note missing <tpc>")
        }
        var accidental: Accidental?
        if let subtype = node.first("Accidental")?.first("subtype")?.text {
            accidental = Accidental(mscxSubtype: subtype)
        }
        return Note(pitch: pitch, tpc: tpc, accidental: accidental)
    }
}
