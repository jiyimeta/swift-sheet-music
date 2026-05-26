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
        // MS2 / MS3 legacy tie encoding: `<Tie id="N">` directly on
        // the start note, `<endSpanner id="N"/>` on the end note.
        // C++: MuseScore 2 `libmscore/note.cpp` `Note::read`. Only
        // ties attach to notes at this level in MS2 (slurs sit on
        // chords / segments, glissandi use their own `<Glissando>`
        // element), so any note-level `<endSpanner>` is a tie end.
        if node.children.contains(where: { $0.name == "Tie" }) { tieForward = 1 }
        if node.children.contains(where: { $0.name == "endSpanner" }) { tieBack = 1 }
        let headType = decodeHeadType(node.first("head")?.text)
        // MuseScore writes `<play>0</play>` only when the note is
        // muted; the element is absent (→ true) for normal notes.
        let play = node.first("play")?.text != "0"
        return Note(
            pitch: pitch,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack,
            glissando: glissando,
            headType: headType,
            play: play,
        )
    }

    /// Normalise `<head>` to the MS3+ string form. MS2 writes an integer
    /// (`NoteHead::Group` enum, C++: MuseScore 2 `libmscore/note.h`); the
    /// renderer (`NoteheadRenderer`) keys off the string names. Returning
    /// the raw integer would silently fall back to "normal", so the
    /// drum staff loses cross / diamond / triangle heads.
    private static func decodeHeadType(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let n = Int(raw) {
            switch n {
            case 0: return "normal"
            case 1: return "cross"
            case 2: return "diamond"
            case 3: return "triangle-up"
            case 4: return "mi"
            case 5: return "slash"
            case 6: return "xcircle"
            case 7: return "do"
            case 8: return "re"
            case 9: return "fa"
            case 10: return "la"
            case 11: return "ti"
            case 12: return "sol"
            case 13: return "alt-brevis"
            default: return nil
            }
        }
        return raw
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
        return Glissando(
            style: style,
            visualType: visualType,
            easeIn: Int(easeIn) ?? 0,
            easeOut: Int(easeOut) ?? 0,
            text: decodeGlissandoText(node, visualType: visualType),
        )
    }

    /// Recover the glissando label, applying MuseScore's per-type default
    /// when `<text>` is absent. MuseScore 4's writer omits the element
    /// when the value matches `Glissando::propertyDefault(Pid::GLISS_TEXT)`
    /// (STRAIGHT → "gliss.", WAVY → ""), so an absent `<text>` means
    /// "use default" — not "no label". An empty `<text></text>` is a
    /// user-cleared label and stays nil.
    private static func decodeGlissandoText(
        _ node: XMLTreeNode,
        visualType: Glissando.VisualType,
    ) -> String? {
        guard let textNode = node.first("text") else {
            return visualType == .straight ? "gliss." : nil
        }
        let raw = textNode.text ?? ""
        return raw.isEmpty ? nil : raw
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
