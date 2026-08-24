import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Note {
    static func decode(_ node: XMLTreeNode) throws -> Note {
        guard let pitchText = node.first("pitch")?.text, let pitch = Int(pitchText) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.note.missingPitch",
                message: "Note missing <pitch>",
                location: "Note",
            ))
        }
        guard let tpcText = node.first("tpc")?.text, let tpc = Int(tpcText) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.note.missingTpc",
                message: "Note missing <tpc>",
                location: "Note",
            ))
        }
        let (accidental, accidentalBracket, accidentalRole) = decodeAccidentalNode(node)
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
        // MuseScore writes `<small>1</small>` on the note when it is
        // displayed at a reduced size; absent means normal size.
        let isSmall = node.first("small")?.text == "1"
        // MuseScore writes `<play>0</play>` only when the note is
        // muted; the element is absent (→ true) for normal notes.
        let play = node.first("play")?.text != "0"
        let parentheses = decodeParentheses(node)
        let (userVelocity, velocityType) = decodeVelocity(node)
        var note = Note(
            pitch: pitch,
            tpc: tpc,
            accidental: accidental,
            accidentalBracket: accidentalBracket,
            accidentalRole: accidentalRole,
            tieForward: tieForward,
            tieBack: tieBack,
            glissando: glissando,
            headType: headType,
            parentheses: parentheses,
            isSmall: isSmall,
            play: play,
            userVelocity: userVelocity,
            velocityType: velocityType,
        )
        note.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return note
    }

    /// Decode the per-note velocity override: `<velocity>` (the value)
    /// plus `<veloType>` (how to apply it).
    ///
    /// The default for an absent `<veloType>` is *version-dependent*,
    /// which is why this reads `MSCXParserContext.version`:
    ///
    /// * MuseScore 3 defaulted to `offset`
    ///   (`Note::propertyDefault(Pid::VELO_TYPE)` returns
    ///   `ValueType::OFFSET_VAL` in 3.6.2's `libmscore/note.cpp`) and so
    ///   wrote `<veloType>user</veloType>` explicitly. A bare
    ///   `<velocity>-20</velocity>` in a 3.x file therefore means "20%
    ///   quieter than the dynamic".
    /// * MuseScore 4 dropped the property from its writer entirely and
    ///   defaults to `user`, so a bare `<velocity>96</velocity>` in a
    ///   4.x file is "sound this note at MIDI velocity 96".
    ///
    /// Note this diverges from MuseScore 4's *reader*, which discards
    /// pre-4.0 `<velocity>` values outright (`read400::TRead::readProperties`
    /// has an explicit "converting is non-trivial, so ignore" branch).
    /// Honoring them costs nothing here because the offset form is
    /// resolved at render time, when the dynamic's velocity is known —
    /// exactly where MuseScore 3 resolved it.
    ///
    /// Velocity type is normalized to the model default (`.user`) when
    /// there is no override, so a v3 file without note velocities
    /// decodes to exactly the same `Note` values as a v4 one. That also
    /// declines to reproduce one MuseScore 3 misfeature: 3.6.2's
    /// `playNote` called `customizeVelocity` unguarded, so a note
    /// carrying `<veloType>user</veloType>` with no `<velocity>` (type
    /// off default, value at it) resolved to `limit(0, 1, 127)` = 1 and
    /// was effectively silent. MuseScore 4 added the
    /// `userVelocity() != 0` guard and drops such values on read anyway;
    /// muting a note over it would be strictly worse.
    private static func decodeVelocity(
        _ node: XMLTreeNode,
    ) -> (userVelocity: Int, velocityType: NoteVelocityType) {
        guard let text = node.first("velocity")?.text,
              let userVelocity = Int(text),
              userVelocity != 0
        else {
            return (0, .user)
        }
        let versionDefault: NoteVelocityType =
            switch MSCXParserContext.version ?? .v4 {
            case .v2, .v3: .offset
            case .v4: .user
            }
        let velocityType = (node.first("veloType")?.text)
            .flatMap(NoteVelocityType.init(mscxToken:)) ?? versionDefault
        return (userVelocity, velocityType)
    }

    /// Decode the `<Accidental>` child of a `<Note>` element.
    ///
    /// Returns the decoded `Accidental` case (nil for missing or unknown subtype),
    /// the `AccidentalBracket` (`.none` when absent or unrecognized), and the
    /// `AccidentalRole` (`.user` when `<role>1</role>` is present, else `.auto`
    /// — MuseScore only writes `<role>` for USER accidentals).
    /// Unknown `<subtype>` values emit `mscx.accidental.unsupportedSubtype`.
    private static func decodeAccidentalNode(
        _ node: XMLTreeNode,
    ) -> (accidental: Accidental?, bracket: AccidentalBracket, role: AccidentalRole) {
        guard let accNode = node.first("Accidental") else { return (nil, .none, .auto) }
        var accidental: Accidental?
        if let subtype = accNode.first("subtype")?.text {
            if let decoded = Accidental(mscxSubtype: subtype) {
                accidental = decoded
            } else {
                mscxDecoderWarn(
                    code: "mscx.accidental.unsupportedSubtype",
                    message: "Unknown <Accidental><subtype> '\(subtype)' — accidental dropped",
                )
            }
        }
        var bracket: AccidentalBracket = .none
        if let text = accNode.first("bracket")?.text, let n = Int(text) {
            bracket = AccidentalBracket(rawValue: n) ?? .none
        }
        // `<role>1</role>` → USER; absent or 0 → AUTO. MuseScore writes
        // the element only for USER accidentals.
        let role: AccidentalRole = (accNode.first("role")?.text).flatMap(Int.init) == 1
            ? .user : .auto
        return (accidental, bracket, role)
    }

    /// Decode a notehead parenthesis from a `<Note>` element across the two
    /// note-level MuseScore representations. Chord-level rep3
    /// (`<NoteParenGroup>`) is handled in `Chord.decode`.
    ///
    /// * rep2 (4.6): `<parentheses>both</parentheses>` text token.
    /// * rep1 (≤4.5): `<Symbol><name>noteheadParenthesisLeft/Right</name></Symbol>`.
    ///
    /// Cosmetic: unknown / absent → `.none` (no throw, no diagnostic).
    private static func decodeParentheses(_ node: XMLTreeNode) -> NoteParentheses {
        // rep2: explicit <parentheses> token wins.
        if let token = node.first("parentheses")?.text {
            return NoteParentheses(mscxToken: token)
        }
        // rep1: SMuFL parenthesis symbols attached to the note.
        var left = false
        var right = false
        for symbol in node.all("Symbol") {
            switch symbol.first("name")?.text {
            case "noteheadParenthesisLeft": left = true
            case "noteheadParenthesisRight": right = true
            default: continue
            }
        }
        if left, right { return .both }
        if left { return .left }
        if right { return .right }
        // Defensive: 4.6 generic <Parenthesis> children without the
        // <parentheses> property still mean the note is parenthesized.
        if node.children.contains(where: { $0.name == "Parenthesis" }) { return .both }
        return .none
    }

    /// Normalize `<head>` to a MS4 string token.
    ///
    /// MS2 writes an integer (`NoteHead::Group` enum, C++: MuseScore 2
    /// `libmscore/note.h`); MS3 and MS4 use string tokens from
    /// `MSCXDecoder.knownHeadTokens`. Returning the raw integer would
    /// silently fall back to "normal", losing cross / diamond / triangle
    /// heads in drum staves.
    ///
    /// Unknown integers and unrecognised string tokens (except `"custom"`)
    /// emit `mscx.note.unsupportedHeadType` via `mscxDecoderWarn` and
    /// return `nil`, which the renderer treats as "normal".
    ///
    /// C++: `NoteHead::Group` (`libmscore/note.h:37-69`),
    ///      `TConv::fromXml(const AsciiStringView&, NoteHeadGroup)`
    ///      (`typesconv.cpp:1145`).
    private static func decodeHeadType(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let n = Int(raw) {
            // MS2 integer → MS4 token (Appendix A.4).
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
            case 13: return "altbrevis"
            default:
                mscxDecoderWarn(
                    code: "mscx.note.unsupportedHeadType",
                    message: "Unknown MS2 <head> integer \(n) — head dropped",
                )
                return nil
            }
        }
        // MS3 / MS4 string token.
        if raw == "custom" { return raw }
        guard MSCXDecoder.knownHeadTokens.contains(raw) else {
            mscxDecoderWarn(
                code: "mscx.note.unsupportedHeadType",
                message: "Unknown <head> token '\(raw)' — head dropped",
            )
            return nil
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
        // MuseScore serializes these as ALL-CAPS tokens. Be tolerant of the
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
