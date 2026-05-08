import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension TimeSignature {
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "TimeSig",
            children: [
                XMLTreeNode(name: "sigN", text: String(numerator)),
                XMLTreeNode(name: "sigD", text: String(denominator)),
            ]
        )
    }
}
