import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension KeySignature {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        let childName: String
        switch options.targetVersion {
        case .v2, .v3: childName = "accidental"
        case .v4: childName = "concertKey"
        }
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: childName, text: String(concertKey)),
        ]
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "KeySig", children: children)
    }
}
