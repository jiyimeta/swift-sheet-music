import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension BarLine {
    private static let consumedBarLineChildren: Set = [
        "color", "subtype", "visible",
    ]

    static func decode(_ node: XMLTreeNode) throws -> BarLine {
        var bar = BarLine(
            subtype: node.first("subtype")?.text,
            preservedMarkup: node.preservedMarkup(consuming: consumedBarLineChildren),
        )
        bar.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return bar
    }
}
