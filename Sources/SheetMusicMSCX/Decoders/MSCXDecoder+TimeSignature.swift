import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension TimeSignature {
    static func decode(_ node: XMLTreeNode) throws -> TimeSignature {
        guard let nText = node.first("sigN")?.text, let n = Int(nText) else {
            throw SheetMusicError.malformedScore(reason: "TimeSig missing <sigN>")
        }
        guard let dText = node.first("sigD")?.text, let d = Int(dText) else {
            throw SheetMusicError.malformedScore(reason: "TimeSig missing <sigD>")
        }
        return TimeSignature(numerator: n, denominator: d)
    }
}
