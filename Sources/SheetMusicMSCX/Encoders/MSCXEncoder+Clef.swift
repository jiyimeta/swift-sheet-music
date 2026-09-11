import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // `<eid>` is the first child MuseScore itself writes.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(XMLTreeNode(name: "concertClefType", text: concertClefType))
        if let transposingClefType {
            children.append(XMLTreeNode(
                name: "transposingClefType", text: transposingClefType,
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Clef", children: children)
    }
}
