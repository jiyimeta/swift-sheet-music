import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Clef {
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "concertClefType", text: concertClefType),
        ]
        if let transposingClefType {
            children.append(XMLTreeNode(
                name: "transposingClefType", text: transposingClefType
            ))
        }
        return XMLTreeNode(name: "Clef", children: children)
    }
}
