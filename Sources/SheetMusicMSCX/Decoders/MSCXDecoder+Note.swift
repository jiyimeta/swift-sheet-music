import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Note {
    static func decode(_ node: XMLTreeNode) throws -> Note {
        guard let pitchText = node.first("pitch")?.text, let pitch = Int(pitchText) else {
            throw SheetMusicError.malformedScore(reason: "Note missing <pitch>")
        }
        guard let tpcText = node.first("tpc")?.text, let tpc = Int(tpcText) else {
            throw SheetMusicError.malformedScore(reason: "Note missing <tpc>")
        }
        var accidental: Accidental?
        if let subtype = node.first("Accidental")?.first("subtype")?.text {
            accidental = Accidental(mscxSubtype: subtype)
        }
        // MuseScore 5.x encodes ties inside `<Note>` as
        // `<Spanner type="Tie">` with `<next>` (start) or `<prev>` (end).
        // Numbering is positional in MSCX; default to 1 when present.
        var tieForward: Int?
        var tieBack: Int?
        var glissando: Glissando?
        for spanner in node.all("Spanner") {
            switch spanner.attributes["type"] {
            case "Tie":
                if spanner.children.contains(where: { $0.name == "next" }) { tieForward = 1 }
                if spanner.children.contains(where: { $0.name == "prev" }) { tieBack = 1 }
            case "Glissando":
                // The Glissando block is only present on the start note
                // (the one with <next>). End notes carry only <prev>.
                if let glissNode = spanner.first("Glissando"),
                   spanner.children.contains(where: { $0.name == "next" })
                {
                    glissando = decodeGlissando(glissNode)
                }
            default:
                continue
            }
        }
        let headType = node.first("head")?.text
        return Note(
            pitch: pitch,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack,
            glissando: glissando,
            headType: headType
        )
    }

    /// Decode a `<Glissando>` block (the child of `<Spanner type="Glissando">`).
    /// MuseScore 4's writer (`TWrite::write(const Glissando*, …)`) emits
    /// `<glissandoStyle>`, `<easeInSpin>`, `<easeOutSpin>`, `<text>`, and
    /// `<subtype>` (0=STRAIGHT, 1=WAVY). Older mscx used `<easeIn>`/`<easeOut>`.
    /// Unknown or missing fields fall back to MuseScore's defaults.
    private static func decodeGlissando(_ node: XMLTreeNode) -> Glissando {
        let style = node.first("glissandoStyle")
            .flatMap { parseGlissandoStyle($0.text) } ?? .chromatic
        let easeIn = node.first("easeInSpin")?.text
            ?? node.first("easeIn")?.text ?? "0"
        let easeOut = node.first("easeOutSpin")?.text
            ?? node.first("easeOut")?.text ?? "0"
        let visualType: Glissando.VisualType
        switch node.first("subtype")?.text {
        case "1", "wavy", "WAVY":
            visualType = .wavy
        default:
            visualType = .straight
        }
        let text = node.first("text")?.text
        return Glissando(
            style: style,
            visualType: visualType,
            easeIn: Int(easeIn) ?? 0,
            easeOut: Int(easeOut) ?? 0,
            text: text?.isEmpty == false ? text : nil
        )
    }

    private static func parseGlissandoStyle(_ text: String) -> Glissando.Style? {
        // MuseScore serialises these as ALL-CAPS tokens. Be tolerant of the
        // lower-case forms that appear in older files (e.g. "chromatic").
        switch text.uppercased() {
        case "CHROMATIC": return .chromatic
        case "DIATONIC": return .diatonic
        case "WHITE_KEYS": return .whiteKeys
        case "BLACK_KEYS": return .blackKeys
        case "PORTAMENTO": return .portamento
        default: return nil
        }
    }
}
