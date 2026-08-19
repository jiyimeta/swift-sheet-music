import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StaffText {
    /// Build a `<StaffText>` or `<SystemText>` element. Mirrors
    /// `StaffText.decode(_:isSystemText:)` — emits `<text>`, optional
    /// `<color>` (RGBA attributes), optional `<offset>` (xy
    /// attributes), `<visible>0` when hidden, and any per-element
    /// `TextProperties`. The element name flips between `StaffText`
    /// and `SystemText` based on `isSystemText` so the parser routes
    /// to the same struct on the way back.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "text", text: text),
        ]
        if let color {
            children.append(XMLTreeNode(
                name: "color",
                attributes: [
                    "r": String(color.red),
                    "g": String(color.green),
                    "b": String(color.blue),
                    "a": String(color.alpha),
                ],
            ))
        }
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ],
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        return XMLTreeNode(
            name: isSystemText ? "SystemText" : "StaffText",
            children: children,
        )
    }
}
