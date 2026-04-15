import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Clef {
    static func decode(_ node: XMLTreeNode) throws -> Clef {
        let concert = node.first("concertClefType")?.text ?? "G"
        let transposing = node.first("transposingClefType")?.text
        return Clef(concertClefType: concert, transposingClefType: transposing)
    }
}
