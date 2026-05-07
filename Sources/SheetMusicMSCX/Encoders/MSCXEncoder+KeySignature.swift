import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension KeySignature {
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "KeySig",
            children: [
                XMLTreeNode(name: "concertKey", text: String(concertKey)),
            ]
        )
    }
}
