import Foundation

extension Chord {
    static func decode(_ node: XMLNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let duration = NoteDuration(mscxName: durationText)
        else {
            throw MuseScoreParserError.malformedScore(reason: "Chord missing <durationType>")
        }
        let notes = try node.all("Note").map { try Note.decode($0) }
        return Chord(duration: duration, notes: notes)
    }
}
