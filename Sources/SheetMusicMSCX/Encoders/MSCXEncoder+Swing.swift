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
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            encodeText(
                text,
                preservedTextMarkup: preservedTextMarkup,
                options: options,
            ),
        ]
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
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(
            name: isSystemText ? "SystemText" : "StaffText",
            children: children,
        )
    }
}
