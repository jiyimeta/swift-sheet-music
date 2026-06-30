import SheetMusicCore

// Drum-staff recognition. The PDF importer detects a percussion clef per
// measure and `decodePercussion` remaps its noteheads to GM drumset key
// numbers — but the assembled part still reads as a pitched "voice"
// instrument. This pass promotes that per-measure detection to the
// part / staff / instrument level so the part is a real GM drum kit:
// playback routes to GM channel 10 (`useDrumset`) instead of a melodic
// channel, transposition is skipped (`group == "percussion"`), and the
// layout positions noteheads by drum line (`drumLineMap`) instead of the
// pitched diatonic formula.

extension PDFImporter {
    /// MuseScore 3's default drumset `<Drum pitch><line>` table — the same
    /// per-pitch staff-line map every percussion staff carries in an mscz,
    /// and the table whose lines positioned the noteheads in the exported
    /// PDF. Key = GM channel-10 key number; value = MuseScore line
    /// (0 = top staff line, 8 = bottom, negative = above the staff).
    ///
    /// The lines for the pitches `percussionMidi` can emit (36, 37, 38, 42,
    /// 43, 44, 45, 46, 47, 49, 50, 51, 55) match its documented positions
    /// exactly, so a decoded drum note re-renders on the line it was
    /// engraved on. The layout reads it as `step = 4 - line` (see
    /// `LayoutEngine+Placement`).
    static let defaultDrumLineMap: [Int: Int] = [
        35: 7, 36: 7, 37: 3, 38: 3, 40: 3, 41: 5, 42: -1, 43: 5,
        44: 9, 45: 2, 46: 1, 47: 1, 48: 0, 49: -2, 50: 0, 51: 0,
        52: -3, 53: 0, 54: 2, 55: -3, 56: 1, 57: -3, 59: 2, 63: 4, 64: 6,
    ]

    /// True when a staff carries a percussion clef anywhere — the signal
    /// the importer uses to recognize a drum staff. `decodePercussion`
    /// already remapped this staff's noteheads to GM drumset key numbers
    /// under that clef.
    static func staffIsPercussion(_ staff: SheetMusicCore.Staff) -> Bool {
        for measure in staff.measures {
            for voice in measure.voices {
                for element in voice.elements {
                    if case let .clef(clef) = element,
                       clef.concertClefType == "PERCUSSION"
                    {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Mark every percussion staff `group = "percussion"` (+ perc staff
    /// type / default clef), and turn any part holding one into a GM
    /// drumset instrument (`useDrumset`, default drum line map). Parts with
    /// no percussion staff are left untouched — the common case, so the
    /// pitched assembly path sees no change.
    static func markPercussionStaves(_ parts: inout [Part]) {
        for partIndex in parts.indices {
            var partHasPercussion = false
            for staffIndex in parts[partIndex].staves.indices
                where staffIsPercussion(parts[partIndex].staves[staffIndex])
            {
                partHasPercussion = true
                parts[partIndex].staves[staffIndex].group = "percussion"
                parts[partIndex].staves[staffIndex].staffType = "perc5Line"
                parts[partIndex].staves[staffIndex].defaultClefType = "PERC"
            }
            guard partHasPercussion else { continue }
            var instrument = parts[partIndex].instrument
            instrument.id = "drumset"
            instrument.useDrumset = true
            if instrument.drumLineMap.isEmpty {
                instrument.drumLineMap = defaultDrumLineMap
            }
            parts[partIndex].instrument = instrument
        }
    }
}
