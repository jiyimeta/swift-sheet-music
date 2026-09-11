import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension BarLine {
    /// Build a `<BarLine>` element. Mirrors `BarLine.decode(_:)` —
    /// emits a `<subtype>` child only when set; the absent default
    /// resolves to a normal bar line on re-parse.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // `<eid>` is the first child MuseScore itself writes.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        if let subtype {
            children.append(XMLTreeNode(name: "subtype", text: subtype))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "BarLine", children: children)
    }
}
