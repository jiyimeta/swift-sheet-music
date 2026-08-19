import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Swing {
    /// Build the `<StaffText>` / `<SystemText>` element with an
    /// embedded `<swing unit ratio>` marker child. Mirrors
    /// `Swing.decode(_:isSystemText:)` and the encoder structure of
    /// `MSCXEncoder+StaffText`. The element name flips between
    /// `StaffText` and `SystemText` based on `isSystemText` so the
    /// parser routes it back through the same swing path.
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
        // The `<swing>` marker child distinguishes this from a
        // regular StaffText/SystemText; the unit attribute is
        // emitted even when `.off` so the swing-disabling form
        // (`unit=""`) round-trips faithfully.
        children.append(XMLTreeNode(
            name: "swing",
            attributes: [
                "unit": unit.mscxString,
                "ratio": String(ratio),
            ],
        ))
        return XMLTreeNode(
            name: isSystemText ? "SystemText" : "StaffText",
            children: children,
        )
    }
}
