import Foundation

extension Rest {
    static func decode(_ node: XMLNode) throws -> Rest {
        guard
            let durationText = node.first("durationType")?.text,
            let duration = NoteDuration(mscxName: durationText)
        else {
            throw MuseScoreParserError.malformedScore(reason: "Rest missing <durationType>")
        }
        return Rest(duration: duration)
    }
}
