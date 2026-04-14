import Foundation

extension Chord {
    static func decode(_ node: XMLNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let baseDuration = NoteDuration(mscxName: durationText)
        else {
            throw MuseScoreParserError.malformedScore(reason: "Chord missing/invalid <durationType>")
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        let duration = baseDuration.dotted(dots)
        let notes = try node.all("Note").map { try Note.decode($0) }
        return Chord(duration: duration, notes: notes)
    }
}
