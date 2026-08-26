import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    static func decode(_ node: XMLTreeNode) throws -> Clef {
        let concert = node.first("concertClefType")?.text ?? "G"
        let transposing = node.first("transposingClefType")?.text
        var clef = Clef(concertClefType: concert, transposingClefType: transposing)
        clef.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return clef
    }
}
