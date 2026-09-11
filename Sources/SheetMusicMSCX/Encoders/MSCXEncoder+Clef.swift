import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(name: "concertClefType", text: concertClefType))
        if let transposingClefType {
            children.append(XMLTreeNode(
                name: "transposingClefType", text: transposingClefType,
            ))
        }
        // `<eid>` sits here, not first: `TWrite::write(const Clef*, ...)`
        // (`rw/write/twrite.cpp:1247-1262`) writes the concert/transposing
        // clef type (and `isHeader`/`isCourtesy`/etc., unmodeled here)
        // before calling `writeItemProperties` — the `<eid>` writer — right
        // where `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Clef", children: children)
    }
}
