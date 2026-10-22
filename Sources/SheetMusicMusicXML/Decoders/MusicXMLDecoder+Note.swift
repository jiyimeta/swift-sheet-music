import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Decodes one MusicXML `<note>` element. Returns either a new `VoiceElement`
/// to append to the current voice, or an instruction to fold this note into
/// the preceding chord (when the note carries `<chord/>`).
enum MusicXMLNoteDecoder {
    enum Decoded {
        /// Append the given elements in order. Typical: a single Chord or Rest.
        /// A fermata on the note prepends a `.fermata` element so it precedes
        /// the chord/rest in the resulting voice, matching MuseScore's MSCX
        /// layout where `<Fermata>` sits as a sibling just before its target.
        /// Breath marks / caesuras (when present) are appended after the
        /// chord/rest — `.chord(...), .breath(...)` — matching MuseScore's
        /// segment-position semantics ("breath taken after this note").
        case new([VoiceElement])
        /// The note's pitch is folded into the previous chord. Trailing
        /// breaths (if any) are appended to the same voice after the fold,
        /// since the host chord remains the previous one, and the note's
        /// articulations join the host chord's.
        case foldIntoLastChord(Note, NoteDuration, trailingBreaths: [Breath], articulations: [ChordArticulation])
        /// A grace note (`<grace>`), which takes no voice time: it waits for the chord it leans on
        /// (`StaffMeasureBuilder.appendGrace`). `joinsChord` is `<chord/>` — the note joins the pending grace chord
        /// rather than opening one — and `endsAfterGraces` a slur or wavy line ending on it, which makes the graces so
        /// far lean back on the previous chord instead (MuseScore's `mustStopGraceAFter`).
        case grace(Note, GraceChordShape, joinsChord: Bool, endsAfterGraces: Bool)
    }

    /// The type and the drawn duration of the grace chord a grace note opens.
    struct GraceChordShape: Equatable {
        let graceType: GraceType
        let duration: NoteDuration
    }

    static func decodeNote(
        node: XMLTreeNode,
        divisions: DivisionsContext,
        existingVoiceElements: [VoiceElement],
        drumTable: MusicXMLDrumTable = MusicXMLDrumTable(),
        octaveShift: Int = 0,
    ) throws -> Decoded {
        let isRest = node.children.contains(where: { $0.name == "rest" })
        let isChord = node.children.contains(where: { $0.name == "chord" })

        guard let duration = MusicXMLDuration.decode(note: node, divisions: divisions) else {
            throw missingUsableDuration()
        }

        let fermata = decodeFermata(node)
        let prefix: [VoiceElement] = fermata.map { [.fermata($0)] } ?? []
        let breaths = decodeBreaths(node)
        let suffix: [VoiceElement] = breaths.map { .breath($0) }

        if isRest {
            let restNode = node.children.first(where: { $0.name == "rest" })
            let isMeasureRest = restNode?.attributes["measure"] == "yes"
            if isMeasureRest {
                // `<duration>` (which `MusicXMLDuration.decode` already
                // consumed for divisions-cursor correctness) is
                // informational under the `.measure` marker model.
                return .new(prefix + [.rest(duration: .measure)] + suffix)
            }
            return .new(prefix + [.rest(duration: duration)] + suffix)
        }

        let midi: Int
        let tpc: Int
        if let pitchNode = node.first("pitch") {
            (midi, tpc) = try written(PitchDecoder.decode(pitchNode), octaveShift: octaveShift)
        } else if let unpitchedNode = node.first("unpitched") {
            // Unpitched percussion: prefer the part's drum table (built from
            // <score-part>'s <midi-instrument><midi-unpitched>) so the note
            // plays the GM percussion pitch the composer intended. Fall back
            // to the staff-position display pitch if no mapping is registered.
            let instrumentRef = node.first("instrument")?.attributes["id"]
            if let id = instrumentRef, let drumPitch = drumTable.pitchByInstrumentId[id] {
                midi = drumPitch
                tpc = 14 // unpitched notes have no tonal-pitch meaning
            } else {
                (midi, tpc) = try PitchDecoder.decodeUnpitched(unpitchedNode)
            }
        } else {
            throw missingNoteBody()
        }
        let accidental = decodeAccidental(node)
        let (tieForward, tieBack) = decodeTies(node)
        let parentheses = decodeNoteheadParentheses(node)
        let note = Note(
            pitch: midi,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack,
            headType: headType(noteheadValue: node.first("notehead")?.text),
            parentheses: parentheses,
            userVelocity: decodeUserVelocity(node),
        )

        if let grace = decodeGrace(node, note: note, duration: duration, isChord: isChord) { return grace }

        let articulations = decodeArticulations(node)
        if isChord {
            return .foldIntoLastChord(note, duration, trailingBreaths: breaths, articulations: articulations)
        }

        let arpeggio = decodeArpeggio(node)
        let lyrics = decodeLyrics(node)
        let chord = Chord(
            duration: duration, notes: [note],
            arpeggio: arpeggio, lyrics: lyrics, articulations: articulations,
        )
        _ = existingVoiceElements // reserved for future use (e.g. tie backrefs)
        return .new(prefix + [.chord(chord)] + suffix)
    }

    /// The written pitch of a sounding `<pitch>` under an octave shift (`xmlSetPitch`, `P2:290-310`): `midi + 12 ×
    /// octaveShift`, clamped to 0…127 as MuseScore clamps it. An `<unpitched>` note is never shifted.
    private static func written(_ pitch: (midi: Int, tpc: Int), octaveShift: Int) -> (midi: Int, tpc: Int) {
        (min(max(pitch.midi + 12 * octaveShift, 0), 127), pitch.tpc)
    }

    /// `.grace` for a `<note>` that carries `<grace>`, nil for any other.
    private static func decodeGrace(
        _ node: XMLTreeNode, note: Note, duration: NoteDuration, isChord: Bool,
    ) -> Decoded? {
        guard let graceNode = node.first("grace") else { return nil }
        let shape = GraceChordShape(
            graceType: graceType(typeName: node.first("type")?.text, slash: graceNode.attributes["slash"] == "yes"),
            duration: duration,
        )
        return .grace(note, shape, joinsChord: isChord, endsAfterGraces: endsAfterGraces(node))
    }

    /// MuseScore's `graceNoteType` (`importmusicxmlpass2.cpp`): a slashed grace is an acciaccatura; an unslashed one
    /// is an appoggiatura, or `grace4` / `grace16` / `grace32` for a quarter, 16th or 32nd `<type>`.
    static func graceType(typeName: String?, slash: Bool) -> GraceType {
        if slash { return .acciaccatura }
        switch typeName {
        case "quarter": return .grace4
        case "16th": return .grace16
        case "32nd": return .grace32
        default: return .appoggiatura
        }
    }

    /// Whether a slur or a wavy line stops on this grace note — MuseScore's `mustStopGraceAFter`, the sign that the
    /// graces up to here are after-graces of the note before them.
    private static func endsAfterGraces(_ node: XMLTreeNode) -> Bool {
        guard let notations = node.first("notations") else { return false }
        let slurStops = notations.all("slur").contains { $0.attributes["type"] == "stop" }
        let wavyLineStops = notations.all("ornaments").contains { ornaments in
            ornaments.all("wavy-line").contains { $0.attributes["type"] == "stop" }
        }
        return slurStops || wavyLineStops
    }

    /// Decode `<note dynamics="…">` into an absolute per-note MIDI
    /// velocity. MusicXML expresses the attribute as a percentage where
    /// 100 means "the default forte level", which the spec pins at MIDI
    /// velocity 90 — hence the ×0.9. Absent, unparsable, or
    /// non-positive values mean "no override" (0).
    ///
    /// Mirrors MuseScore's MusicXML importer
    /// (`importmusicxmlpass2.cpp`: `round(doubleAttribute("dynamics") * 0.9)`
    /// guarded by `if (velocity > 0)`), which likewise leaves the note's
    /// velocity type at the absolute `.user` default.
    private static func decodeUserVelocity(_ node: XMLTreeNode) -> Int {
        guard let raw = node.attributes["dynamics"], let percent = Double(raw) else {
            return 0
        }
        let velocity = Int((percent * 0.9).rounded())
        return velocity > 0 ? velocity : 0
    }

    private static func missingUsableDuration() -> SheetMusicError {
        .malformedScore(ScoreFault(
            code: "musicxml.note.missingUsableDuration",
            message: "MusicXML: <note> missing a usable <duration> or <type>",
            location: "note",
        ))
    }

    private static func missingNoteBody() -> SheetMusicError {
        .malformedScore(ScoreFault(
            code: "musicxml.note.missingPitchUnpitchedOrRest",
            message: "MusicXML: <note> has neither <pitch>, <unpitched>, nor <rest>",
            location: "note",
        ))
    }

    /// MusicXML encodes breath marks and caesuras under
    /// `<notations><breath-mark>` / `<notations><caesura>`. Either may
    /// repeat (rare but legal); we return them in document order so the
    /// caller can append `.breath(...)` voice elements after the host
    /// chord, matching MuseScore's segment placement.
    private static func decodeBreaths(_ node: XMLTreeNode) -> [Breath] {
        guard let notations = node.first("notations") else { return [] }
        var result: [Breath] = []
        for child in notations.children {
            switch child.name {
            case "breath-mark":
                result.append(Breath.decodeMusicXMLBreathMark(child))
            case "caesura":
                result.append(Breath.decodeMusicXMLCaesura(child))
            default:
                continue
            }
        }
        return result
    }

    /// MusicXML encodes fermatas under `<notations><fermata>`. The element's text (if any) is the fermata shape
    /// ("normal", "square", "angled", …); empty means normal. Shapes map to MuseScore's `<subtype>` spelling the way
    /// its importer does (`convertFermataToSymId`, `importmusicxmlpass2.cpp:1516`), and the hold is the subtype's file
    /// default, because `addFermataToChord` sets it through `setSymIdAndTimeStretch` — MusicXML carries none.
    private static func decodeFermata(_ node: XMLTreeNode) -> Fermata? {
        guard let notations = node.first("notations") else { return nil }
        guard let fermataNode = notations.first("fermata") else { return nil }
        let shape = fermataNode.text
        let placement = fermataNode.attributes["type"] ?? "upright"
        let above = placement != "inverted"
        let subtype: String
        switch shape {
        case "square":
            subtype = above ? "fermataLongAbove" : "fermataLongBelow"
        case "angled":
            subtype = above ? "fermataShortAbove" : "fermataShortBelow"
        case "double-square":
            subtype = above ? "fermataVeryLongAbove" : "fermataVeryLongBelow"
        case "double-angled":
            subtype = above ? "fermataVeryShortAbove" : "fermataVeryShortBelow"
        case "double-dot":
            subtype = above ? "fermataLongHenzeAbove" : "fermataLongHenzeBelow"
        case "half-curve":
            subtype = above ? "fermataShortHenzeAbove" : "fermataShortHenzeBelow"
        default:
            subtype = above ? "fermataAbove" : "fermataBelow"
        }
        var fermata = Fermata(subtype: subtype, timeStretch: Fermata.fileDefaultTimeStretch(for: subtype))
        // A `type` attribute places it explicitly, as MuseScore's `addFermataToChord` does; without one the voice
        // decides, as for any fermata (`FermataGlyph.placedBelow`).
        if fermataNode.attributes["type"] != nil {
            fermata.elementProperties.placement = above ? .above : .below
        }
        return fermata
    }

    /// MusicXML's `<tie type="start"/>` starts a tie; `<tie type="stop"/>`
    /// ends one. Optional `number` attribute disambiguates overlapping ties
    /// (defaults to 1). A single note can carry both when it's in the middle
    /// of a tied sequence.
    private static func decodeTies(_ node: XMLTreeNode) -> (forward: Int?, back: Int?) {
        var forward: Int?
        var back: Int?
        for tie in node.all("tie") {
            let number = tie.attributes["number"].flatMap { Int($0) } ?? 1
            switch tie.attributes["type"] {
            case "start": forward = number
            case "stop": back = number
            default: continue
            }
        }
        return (forward, back)
    }

    /// MusicXML's `<accidental>` names the visible symbol on the note.
    /// MuseScore's `<Accidental><subtype>` uses SMuFL names like `accidentalSharp`.
    private static func decodeAccidental(_ node: XMLTreeNode) -> Accidental? {
        guard let text = node.first("accidental")?.text, !text.isEmpty else {
            return nil
        }
        switch text {
        case "sharp": return .sharp
        case "flat": return .flat
        case "natural": return .natural
        case "double-sharp", "sharp-sharp": return .doubleSharp
        case "flat-flat": return .doubleFlat
        default: return nil
        }
    }

    /// MusicXML wraps a notehead in parentheses via `<notehead parentheses="yes">`.
    /// We only model the both-sides case (MusicXML has no per-side notehead
    /// parenthesis). Absent element or `parentheses != "yes"` → `.none`.
    private static func decodeNoteheadParentheses(_ node: XMLTreeNode) -> NoteParentheses {
        guard let notehead = node.first("notehead") else { return .none }
        return notehead.attributes["parentheses"] == "yes" ? .both : .none
    }

    /// The MuseScore head group a `<notehead>` value names, as the `Note.headType` token MSCX writes for it.
    /// MuseScore's `convertNotehead` (`importmusicxmlpass2.cpp`), entry for entry. `normal`, a value it has no group
    /// for (`square`, `circle dot`, …) and an absent element all leave the default head, which is nil here.
    private static func headType(noteheadValue: String?) -> String? {
        noteheadValue.flatMap { museScoreHeadGroups[$0] }
    }

    private static let museScoreHeadGroups: [String: String] = [
        "slash": "slash",
        "triangle": "triangle-up",
        "diamond": "diamond",
        "cross": "plus",
        "x": "cross",
        "circle-x": "xcircle",
        "inverted triangle": "triangle-down",
        "slashed": "slashed1",
        "back slashed": "slashed2",
        "do": "do",
        "re": "re",
        "mi": "mi",
        "fa": "fa",
        "fa up": "fa",
        "so": "sol",
        "la": "la",
        "ti": "ti",
    ]

    /// MusicXML encodes arpeggios under `<notations><arpeggiate>`. The optional
    /// `direction` attribute selects MuseScore's subtype.
    private static func decodeArpeggio(_ node: XMLTreeNode) -> Arpeggio? {
        guard let notations = node.first("notations") else { return nil }
        guard let arp = notations.first("arpeggiate") else { return nil }
        let direction = arp.attributes["direction"]
        let subtype: Int
        switch direction {
        case "up": subtype = 1
        case "down": subtype = 2
        default: subtype = 0
        }
        return Arpeggio(subtype: subtype)
    }

    /// MusicXML `<lyric>` children. `<lyric number="N"><text>…</text></lyric>`.
    /// `<syllabic>` classifies word-internal syllables; `<extend/>`
    /// marks a melisma (we leave `ticks` at 0 because MusicXML does
    /// not spell the extent — callers that need a melisma length can
    /// derive it from the covered notes).
    private static func decodeLyrics(_ node: XMLTreeNode) -> [Lyric] {
        var map: [Int: Lyric] = [:]
        for lyricNode in node.all("lyric") {
            let verse = Int(lyricNode.attributes["number"] ?? "1") ?? 1
            let text = lyricNode.first("text")?.text ?? ""
            let syllabic = (lyricNode.first("syllabic")?.text)
                .flatMap(Syllabic.init(mscxValue:)) ?? .single
            map[verse - 1] = Lyric(
                text: text, syllabic: syllabic, ticks: 0,
            )
        }
        guard let maxVerse = map.keys.max() else { return [] }
        return (0 ... maxVerse).map { map[$0] ?? Lyric(text: "") }
    }
}
