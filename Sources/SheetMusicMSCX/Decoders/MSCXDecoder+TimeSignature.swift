import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TimeSignature {
    static func decode(_ node: XMLTreeNode) throws -> TimeSignature {
        guard let nText = node.first("sigN")?.text, let n = Int(nText) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.timeSig.missingSigN",
                message: "TimeSig missing <sigN>",
                location: "TimeSig",
            ))
        }
        guard let dText = node.first("sigD")?.text, let d = Int(dText) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.timeSig.missingSigD",
                message: "TimeSig missing <sigD>",
                location: "TimeSig",
            ))
        }
        var timeSig = TimeSignature(numerator: n, denominator: d)
        timeSig.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return timeSig
    }
}
