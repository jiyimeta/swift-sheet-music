import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TimeSignature {
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "sigN", text: String(numerator)),
            XMLTreeNode(name: "sigD", text: String(denominator)),
        ]
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "TimeSig", children: children)
    }
}
