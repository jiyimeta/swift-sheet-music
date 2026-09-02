import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Glissando {
    /// Build the `<Glissando>` payload child of a
    /// `<Spanner type="Glissando">`. Mirrors MuseScore 4's
    /// `TWrite::write(const Glissando*, …)` — uppercase style token,
    /// `easeInSpin` / `easeOutSpin` integers, `subtype` 0/1 for
    /// straight/wavy, optional `<text>`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(
                name: "subtype",
                text: visualType == .wavy ? "1" : "0",
            ),
            XMLTreeNode(name: "glissandoStyle", text: style.mscxToken),
            XMLTreeNode(name: "easeInSpin", text: String(easeIn)),
            XMLTreeNode(name: "easeOutSpin", text: String(easeOut)),
        ]
        if let text, !text.isEmpty {
            children.append(XMLTreeNode(name: "text", text: text))
        }
        return XMLTreeNode(name: "Glissando", children: children)
    }
}

extension Glissando.Style {
    /// MuseScore writes these as ALL-CAPS tokens; the decoder accepts
    /// any case but we mirror the writer's output.
    var mscxToken: String {
        switch self {
        case .chromatic: "CHROMATIC"
        case .diatonic: "DIATONIC"
        case .whiteKeys: "WHITE_KEYS"
        case .blackKeys: "BLACK_KEYS"
        case .portamento: "PORTAMENTO"
        }
    }
}
