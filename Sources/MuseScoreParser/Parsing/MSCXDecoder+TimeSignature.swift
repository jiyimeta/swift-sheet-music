import Foundation

extension TimeSignature {
    static func decode(_ node: XMLNode) throws -> TimeSignature {
        guard let nText = node.first("sigN")?.text, let n = Int(nText) else {
            throw MuseScoreParserError.malformedScore(reason: "TimeSig missing <sigN>")
        }
        guard let dText = node.first("sigD")?.text, let d = Int(dText) else {
            throw MuseScoreParserError.malformedScore(reason: "TimeSig missing <sigD>")
        }
        return TimeSignature(numerator: n, denominator: d)
    }
}
