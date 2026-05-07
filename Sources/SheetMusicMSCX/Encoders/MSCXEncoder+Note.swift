import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Note {
    /// Build a `<Note>` element. Phase 1 emits pitch / tpc /
    /// optional accidental / optional headType. Tie / glissando
    /// spanners and lyrics live on the chord and are not round-tripped
    /// in the midi01 vertical slice.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let accidental {
            children.append(XMLTreeNode(
                name: "Accidental",
                children: [
                    XMLTreeNode(
                        name: "subtype",
                        text: accidental.mscxSubtype
                    ),
                ]
            ))
        }
        children.append(XMLTreeNode(name: "pitch", text: String(pitch)))
        children.append(XMLTreeNode(name: "tpc", text: String(tpc)))
        if let headType {
            children.append(XMLTreeNode(name: "head", text: headType))
        }
        return XMLTreeNode(name: "Note", children: children)
    }
}

extension Accidental {
    /// Mirror of `Accidental.init?(mscxSubtype:)` — exhaustive.
    var mscxSubtype: String {
        switch self {
        case .sharp: "accidentalSharp"
        case .flat: "accidentalFlat"
        case .natural: "accidentalNatural"
        case .doubleSharp: "accidentalDoubleSharp"
        case .doubleFlat: "accidentalDoubleFlat"
        }
    }
}
