import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Glissando {
    /// Build the `<Glissando>` payload child of a
    /// `<Spanner type="Glissando">`. Mirrors MuseScore 4's
    /// `TWrite::write(const Glissando*, …)` — version-specific style token,
    /// `easeInSpin` / `easeOutSpin` integers, `subtype` 0/1 for straight/wavy,
    /// optional `<text>`.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(
                name: "subtype",
                text: visualType == .wavy ? "1" : "0",
            ),
            XMLTreeNode(
                name: "glissandoStyle",
                text: style.mscxToken(for: options.targetVersion),
            ),
            XMLTreeNode(name: "easeInSpin", text: String(easeIn)),
            XMLTreeNode(name: "easeOutSpin", text: String(easeOut)),
        ]
        if let text, !text.isEmpty {
            children.append(encodeText(
                text,
                preservedTextMarkup: preservedTextMarkup,
                options: options,
            ))
        }
        return XMLTreeNode(name: "Glissando", children: children)
    }
}

extension Glissando.Style {
    /// MuseScore 4 writes ALL-CAPS tokens with underscores. MuseScore 2/3
    /// instead use lowercase compact key names and a capitalized chromatic
    /// token; their reader treats the v4 key-name spellings as chromatic.
    func mscxToken(for targetVersion: MSCXVersion) -> String {
        switch targetVersion {
        case .v4:
            switch self {
            case .chromatic: "CHROMATIC"
            case .diatonic: "DIATONIC"
            case .whiteKeys: "WHITE_KEYS"
            case .blackKeys: "BLACK_KEYS"
            case .portamento: "PORTAMENTO"
            }
        case .v2, .v3:
            switch self {
            case .chromatic: "Chromatic"
            case .diatonic: "diatonic"
            case .whiteKeys: "whitekeys"
            case .blackKeys: "blackkeys"
            case .portamento: "portamento"
            }
        }
    }
}
