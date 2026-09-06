import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TimeSignature {
    private static let consumedTimeSignatureChildren: Set = [
        "color", "offset", "placement", "showCourtesySig", "sigD", "sigN", "visible",
    ]

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
        // `<showCourtesySig>` is written only when off, so an absent tag means the courtesy is drawn.
        var timeSig = TimeSignature(
            numerator: n, denominator: d,
            showCourtesy: (node.first("showCourtesySig")?.text ?? "1") != "0",
            preservedMarkup: node.preservedMarkup(
                consuming: consumedTimeSignatureChildren,
            ),
        )
        timeSig.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return timeSig
    }
}
