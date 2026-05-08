import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension BarLine {
    /// Build a `<BarLine>` element. Mirrors `BarLine.decode(_:)` —
    /// emits a `<subtype>` child only when set; the absent default
    /// resolves to a normal bar line on re-parse.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let subtype {
            children.append(XMLTreeNode(name: "subtype", text: subtype))
        }
        return XMLTreeNode(name: "BarLine", children: children)
    }
}
