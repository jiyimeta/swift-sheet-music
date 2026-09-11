import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Dynamic {
    /// Build a `<Dynamic>` element. Mirrors `Dynamic.decode(_:)`:
    /// emits `<subtype>`, `<velocity>` (always, so the
    /// default-velocity table on the decoder side is bypassed), and
    /// any per-element `TextProperties`.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children += [
            XMLTreeNode(name: "subtype", text: subtype),
            XMLTreeNode(name: "velocity", text: String(velocity)),
        ]
        // `<eid>` sits here, not first: `TWrite::write(const Dynamic*, ...)`
        // (`rw/write/twrite.cpp:1288-1307`) writes `<subtype>`/`<velocity>`
        // (and other unmodeled Dynamic-only properties) before calling
        // `writeProperties(TextBase*, ...)`, whose own first act is
        // `writeItemProperties` — the `<eid>` writer — right where
        // `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Dynamic", children: children)
    }
}
