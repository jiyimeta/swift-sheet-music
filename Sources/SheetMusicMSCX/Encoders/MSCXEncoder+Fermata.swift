import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Fermata {
    /// Build a `<Fermata>` element. Mirrors the inline fermata
    /// decoding in `MSCXDecoder+Voice.swift` — only the `<subtype>`
    /// glyph name is preserved.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Fermata",
            children: [XMLTreeNode(name: "subtype", text: subtype)]
        )
    }
}
