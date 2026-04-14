import Foundation
import SheetMusicCore

extension Clef {
    static func decode(_ node: XMLNode) throws -> Clef {
        let concert = node.first("concertClefType")?.text ?? "G"
        let transposing = node.first("transposingClefType")?.text
        return Clef(concertClefType: concert, transposingClefType: transposing)
    }
}
