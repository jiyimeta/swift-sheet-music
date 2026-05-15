import Foundation
import SheetMusicCore
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
        case new([VoiceElement])
        case foldIntoLastChord(Note, NoteDuration)
    }

    static func decodeNote(
        node: XMLTreeNode,
        divisions: DivisionsContext,
        existingVoiceElements: [VoiceElement],
        drumTable: MusicXMLDrumTable = MusicXMLDrumTable(),
    ) throws -> Decoded {
        let isRest = node.children.contains(where: { $0.name == "rest" })
        let isChord = node.children.contains(where: { $0.name == "chord" })

        guard let duration = MusicXMLDuration.decode(note: node, divisions: divisions) else {
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: <note> missing a usable <duration> or <type>",
            )
        }

        let fermata = decodeFermata(node)
        let prefix: [VoiceElement] = fermata.map { [.fermata($0)] } ?? []

        if isRest {
            let restNode = node.children.first(where: { $0.name == "rest" })
            let isMeasureRest = restNode?.attributes["measure"] == "yes"
            if isMeasureRest {
                // `<duration>` (which `MusicXMLDuration.decode` already
                // consumed for divisions-cursor correctness) is
                // informational under the `.measure` marker model.
                return .new(prefix + [.rest(duration: .measure)])
            }
            return .new(prefix + [.rest(duration: duration)])
        }

        let midi: Int
        let tpc: Int
        if let pitchNode = node.first("pitch") {
            (midi, tpc) = try PitchDecoder.decode(pitchNode)
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
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: <note> has neither <pitch>, <unpitched>, nor <rest>",
            )
        }
        let accidental = decodeAccidental(node)
        let (tieForward, tieBack) = decodeTies(node)
        let note = Note(
            pitch: midi,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack,
        )

        if isChord {
            return .foldIntoLastChord(note, duration)
        }

        let arpeggio = decodeArpeggio(node)
        let lyrics = decodeLyrics(node)
        let chord = Chord(
            duration: duration, notes: [note],
            arpeggio: arpeggio, lyrics: lyrics,
        )
        _ = existingVoiceElements // reserved for future use (e.g. tie backrefs)
        return .new(prefix + [.chord(chord)])
    }

    /// MusicXML encodes fermatas under `<notations><fermata>`. The element's
    /// text (if any) is the fermata shape ("normal", "square", "angled", …);
    /// empty means normal. We map to MuseScore's `<subtype>` spelling.
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
        default:
            subtype = above ? "fermataAbove" : "fermataBelow"
        }
        return Fermata(subtype: subtype)
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
