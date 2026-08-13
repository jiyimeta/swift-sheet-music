import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Dynamic {
    /// Build a `<Dynamic>` element. Mirrors `Dynamic.decode(_:)`:
    /// emits `<subtype>`, `<velocity>` (always, so the
    /// default-velocity table on the decoder side is bypassed), and
    /// any per-element `TextProperties`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: subtype),
            XMLTreeNode(name: "velocity", text: String(velocity)),
        ]
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        return XMLTreeNode(name: "Dynamic", children: children)
    }
}
