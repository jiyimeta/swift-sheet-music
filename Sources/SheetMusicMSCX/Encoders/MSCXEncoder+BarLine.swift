import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension BarLine {
    /// Build a `<BarLine>` element. Mirrors `BarLine.decode(_:)` —
    /// emits a `<subtype>` child only when set; the absent default
    /// resolves to a normal bar line on re-parse.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let subtype {
            children.append(XMLTreeNode(name: "subtype", text: subtype))
        }
        // `<eid>` sits here, not first: `TWrite::write(const BarLine*, ...)`
        // (`rw/write/twrite.cpp:766-783`) writes the subtype/span
        // properties (and any `el()` items) before calling
        // `writeItemProperties` — the `<eid>` writer — right where
        // `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "BarLine", children: children)
    }
}
