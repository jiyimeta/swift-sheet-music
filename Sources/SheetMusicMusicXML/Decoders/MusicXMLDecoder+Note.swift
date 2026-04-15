import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Decodes one MusicXML `<note>` element. Returns either a new `VoiceElement`
/// to append to the current voice, or an instruction to fold this note into
/// the preceding chord (when the note carries `<chord/>`).
enum MusicXMLNoteDecoder {
    enum Decoded {
        case new(VoiceElement)
        case foldIntoLastChord(Note, NoteDuration)
    }

    static func decodeNote(
        node: XMLTreeNode,
        divisions: DivisionsContext,
        existingVoiceElements: [VoiceElement]
    ) throws -> Decoded {
        let isRest = node.children.contains(where: { $0.name == "rest" })
        let isChord = node.children.contains(where: { $0.name == "chord" })

        guard let duration = MusicXMLDuration.decode(note: node, divisions: divisions) else {
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: <note> missing a usable <duration> or <type>"
            )
        }

        if isRest {
            return .new(.rest(Rest(duration: duration)))
        }

        guard let pitchNode = node.first("pitch") else {
            // Unpitched percussion notes can occur in `<unpitched>`; Phase 0
            // fixtures don't cover them, so treat as malformed for now.
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: <note> has neither <pitch> nor <rest>"
            )
        }
        let (midi, tpc) = try PitchDecoder.decode(pitchNode)
        let accidental = decodeAccidental(node)
        let (tieForward, tieBack) = decodeTies(node)
        let note = Note(
            pitch: midi,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack
        )

        if isChord {
            return .foldIntoLastChord(note, duration)
        }

        let arpeggio = decodeArpeggio(node)
        let chord = Chord(duration: duration, notes: [note], arpeggio: arpeggio)
        _ = existingVoiceElements   // reserved for future use (e.g. tie backrefs)
        return .new(.chord(chord))
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
            case "stop":  back = number
            default:      continue
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
        case "sharp":        return .sharp
        case "flat":         return .flat
        case "natural":      return .natural
        case "double-sharp", "sharp-sharp": return .doubleSharp
        case "flat-flat":    return .doubleFlat
        default:             return nil
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
        case "up":   subtype = 1
        case "down": subtype = 2
        default:     subtype = 0
        }
        return Arpeggio(subtype: subtype)
    }
}
