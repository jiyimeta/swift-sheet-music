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
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
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
        // `<eid>` sits right here, after `<swing>`:
        // `TWrite::writeProperties(const StaffTextBase*, ...)`
        // (`rw/write/twrite.cpp:2867-2895`) writes the `<swing>` tag —
        // this kind's own leading, StaffTextBase-level field — BEFORE
        // calling `writeProperties(toTextBase(item), ..., true)`,
        // whose first act is `writeItemProperties`. This diverges from
        // this encoder's own (pre-existing, out-of-scope) child order,
        // which already writes `<swing>` after `<text>`/mscxChildren
        // rather than before — `<eid>` follows the `<swing>` marker
        // wherever THIS encoder places it, matching the real
        // swing-before-eid relative order without reordering the rest.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(
            name: isSystemText ? "SystemText" : "StaffText",
            children: children,
        )
    }
}
