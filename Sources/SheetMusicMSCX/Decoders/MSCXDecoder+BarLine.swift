import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension BarLine {
    static func decode(_ node: XMLTreeNode) throws -> BarLine {
        var bar = BarLine(subtype: node.first("subtype")?.text)
        bar.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return bar
    }
}
