import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    private static let consumedClefChildren: Set = [
        "color", "concertClefType", "offset", "transposingClefType", "visible",
    ]

    static func decode(_ node: XMLTreeNode) throws -> Clef {
        let concert = node.first("concertClefType")?.text ?? "G"
        let transposing = node.first("transposingClefType")?.text
        var clef = Clef(
            concertClefType: concert,
            transposingClefType: transposing,
            preservedMarkup: node.preservedMarkup(consuming: consumedClefChildren),
        )
        clef.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return clef
    }
}
