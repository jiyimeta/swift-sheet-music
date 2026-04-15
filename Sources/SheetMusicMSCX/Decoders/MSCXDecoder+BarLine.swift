import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension BarLine {
    static func decode(_ node: XMLTreeNode) throws -> BarLine {
        BarLine(subtype: node.first("subtype")?.text)
    }
}
