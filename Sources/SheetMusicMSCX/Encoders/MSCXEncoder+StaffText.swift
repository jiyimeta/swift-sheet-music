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
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(
            name: isSystemText ? "SystemText" : "StaffText",
            children: children,
        )
    }
}
