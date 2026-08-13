import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "concertClefType", text: concertClefType),
        ]
        if let transposingClefType {
            children.append(XMLTreeNode(
                name: "transposingClefType", text: transposingClefType,
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Clef", children: children)
    }
}
