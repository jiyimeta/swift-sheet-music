import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tremolo {
    /// Build the `<Tremolo>` MSCX element. `subtype + span` map to
    /// MuseScore's eight-token alphabet (`r8/r16/r32/r64` single,
    /// `c8/c16/c32/c64` between); `strokeStyle` round-trips the
    /// `<strokeStyle>` integer
    /// when non-default. Inverse of `MSCXDecoder+Tremolo.decode`.
    /// C++: `mu::engraving::TremoloDispatcher::write`.
    func encodeXML() -> XMLTreeNode {
        let token: String
        switch (span, subtype) {
        case (.single, .r8): token = "r8"
        case (.single, .r16): token = "r16"
        case (.single, .r32): token = "r32"
        case (.single, .r64): token = "r64"
        case (.between, .r8): token = "c8"
        case (.between, .r16): token = "c16"
        case (.between, .r32): token = "c32"
        case (.between, .r64): token = "c64"
        }
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: token),
        ]
        switch strokeStyle {
        case .default: break
        case .traditional:
            children.append(XMLTreeNode(name: "strokeStyle", text: "1"))
        case .z:
            children.append(XMLTreeNode(name: "strokeStyle", text: "2"))
        }
        return XMLTreeNode(name: "Tremolo", children: children)
    }
}
