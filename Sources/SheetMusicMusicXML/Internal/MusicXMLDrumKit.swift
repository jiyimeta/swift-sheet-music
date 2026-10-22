import SheetMusicCore
import SheetMusicXMLTools

/// The drum kit a MusicXML drum part implies.
///
/// MuseScore's drumset holds a default line, head and stem per drum, where a MusicXML file holds the actual ones on
/// each note. So its import copies every unpitched note's onto the drum its `<instrument>` names — the last note of a
/// drum deciding, as `setDrumsetDefault` overwrites — and builds the kit from the part's instruments once the part is
/// read (`setDrumset` and `initDrumset` in `importmusicxmlpass2.cpp`).
///
/// The kit is what places the notes. A drum note's pitch is its General MIDI number, so with no line for it the
/// layout reads the note as a pitched one — a bass drum's 36 as C2, octaves below the staff.
struct MusicXMLDrumKit {
    private struct Played {
        let head: String
        let line: Int
        let stem: Int
    }

    private var playedByInstrumentId: [String: Played] = [:]

    /// Keep `note`'s line, head and stem as its drum's. A pitched note, and an unpitched one naming no instrument the
    /// table has a pitch for, set no drum's (`setDrumsetDefault` ignores an id it does not know).
    mutating func record(_ note: XMLTreeNode, clef: NotatedClef, lineCount: Int, table: MusicXMLDrumTable) {
        guard let unpitched = note.first("unpitched"),
              let id = note.first("instrument")?.attributes["id"],
              table.pitchByInstrumentId[id] != nil
        else { return }
        let line = Self.line(of: unpitched, clef: clef, lineCount: lineCount)
        // The drum palette has no automatic direction, so `setDrumset` gives one: down below the middle line.
        let stem = switch note.first("stem")?.text {
        case "up": 1
        case "down": 2
        default: line > 4 ? 2 : 1
        }
        playedByInstrumentId[id] = Played(
            head: MusicXMLNoteDecoder.headType(noteheadValue: note.first("notehead")?.text) ?? "normal",
            line: line, stem: stem,
        )
    }

    /// The part's kit: a drum for every instrument the table has a pitch for, under its `<instrument-name>`. A drum no
    /// note played takes the General MIDI kit's line, head and stem for its pitch. MuseScore leaves one on the top line
    /// with a normal head, which places nothing in the file but would seat the drum there in later note entry.
    /// Instruments sharing a pitch resolve as MuseScore's id-ordered map does: the last id wins.
    func drumset(table: MusicXMLDrumTable) -> [Int: DrumsetEntry] {
        var kit: [Int: DrumsetEntry] = [:]
        for id in table.pitchByInstrumentId.keys.sorted() {
            guard let pitch = table.pitchByInstrumentId[id] else { continue }
            var entry = GMDrumset.entry(forPitch: pitch, line: GMDrumset.entries[pitch]?.line ?? 0)
            entry.name = table.nameByInstrumentId[id] ?? entry.name
            if let played = playedByInstrumentId[id] {
                // `initDrumset`'s `DrumInstrument` takes the default voice.
                entry.head = played.head
                entry.line = played.line
                entry.stem = played.stem
                entry.voiceIndex = 0
            }
            kit[pitch] = entry
        }
        return kit
    }

    /// MuseScore's line (0 = top line) for an unpitched note's display position: the clef's middle line is line 4. A
    /// one- or three-line staff writes its positions as the five-line staff's (`ExportMusicXml::unpitch2xml`), which
    /// `setDrumset` takes back off. An absent display position reads as C4, as `PitchDecoder.decodeUnpitched` does.
    private static func line(of unpitched: XMLTreeNode, clef: NotatedClef, lineCount: Int) -> Int {
        let letter = letters.firstIndex(of: unpitched.first("display-step")?.text ?? "C") ?? 0
        let octave = unpitched.first("display-octave").flatMap { Int($0.text) } ?? 4
        let line = 4 - (octave * 7 + letter - clef.middleLineDiatonicStep)
        switch lineCount {
        case 1: return line - 8
        case 3: return line - 2
        default: return line
        }
    }

    private static let letters = ["C", "D", "E", "F", "G", "A", "B"]
}
