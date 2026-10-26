import SheetMusicCore
import SheetMusicFoundation

/// The written accidentals a measure's key already implies, which MuseScore's import keeps as `user` accidentals
/// (`markUserAccidentals`, `P2:2550-2597`): an `auto` one is redrawn only where the line needs it, so a courtesy ♭
/// under a key with that flat would disappear, from the page and from a saved file.
///
/// An accidental is one when its alteration is the key's on its line, it is the plain sharp, flat or natural of that
/// alteration, and no earlier note of the measure on that line took an accidental the key does not imply — after
/// one, a note back in the key needs its accidental and is left `auto`. The measure is read as MuseScore reads it:
/// by onset, then staff and voice, the part's staves together, each chord from its lowest note; grace notes are not
/// read. The key is the one in force where the measure starts.
enum MusicXMLUserAccidentals {
    /// The part's staves' measure, as built, with the written accidentals the key implies made `user`.
    static func marking(_ built: [StaffMeasureBuilder.Built], keyFifths: Int) -> [StaffMeasureBuilder.Built] {
        var measures = built.map(\.measure)
        mark(&measures, keyFifths: keyFifths)
        return zip(built, measures).map { item, measure in
            var marked = item
            marked.measure = measure
            return marked
        }
    }

    /// One measure of each of the part's staves, with the written accidentals the key implies made `user`.
    static func mark(_ staves: inout [Measure], keyFifths: Int) {
        var neededOnLine: [Int: Bool] = [:]
        for slot in onsets(staves) {
            guard case var .chord(chord) = staves[slot.staff].voices[slot.voice].elements[slot.element]
            else { continue }
            var changed = false
            for noteIndex in chord.notes.indices.sorted(by: { chord.notes[$0].pitch < chord.notes[$1].pitch }) {
                let note = chord.notes[noteIndex]
                guard let accidental = note.accidental else { continue }
                let spelling = Spelling(tpc: note.tpc, pitch: note.pitch)
                let implied = spelling.alteration == keyAlteration(step: spelling.step, fifths: keyFifths)
                    && accidental == plainAccidental(spelling.alteration)
                if implied, neededOnLine[spelling.line] != true {
                    chord.notes.updateNote(at: noteIndex) { $0.accidentalRole = .user }
                    changed = true
                } else if neededOnLine[spelling.line] == nil {
                    neededOnLine[spelling.line] = true
                }
            }
            guard changed else { continue }
            staves[slot.staff].voices[slot.voice].elements.updateValue(at: slot.element) { $0 = .chord(chord) }
        }
    }

    /// Every chord of the measure, by onset, then staff, then voice.
    private static func onsets(_ staves: [Measure]) -> [Slot] {
        var slots: [Slot] = []
        for staff in staves.indices {
            for (voice, content) in staves[staff].voices.enumerated() {
                var onset = Fraction.zeroTick
                for (element, value) in content.elements.values.enumerated() {
                    guard case let .chord(chord) = value else { continue }
                    if !chord.notes.isEmpty {
                        slots.append(Slot(onset: onset, staff: staff, voice: voice, element: element))
                    }
                    if chord.duration != .measure { onset += chord.duration.asFraction }
                }
            }
        }
        return slots.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element, rhs.element)
            if left.onset != right.onset { return left.onset.precedes(right.onset) }
            if left.staff != right.staff { return left.staff < right.staff }
            if left.voice != right.voice { return left.voice < right.voice }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private struct Slot {
        let onset: Fraction
        let staff: Int
        let voice: Int
        let element: Int
    }

    /// A written note's letter, alteration and staff line (its letter counted up from C in octave 0).
    private struct Spelling {
        let step: Int
        let alteration: Int
        let line: Int

        init(tpc: Int, pitch: Int) {
            // Tonal pitch classes run F C G D A E B, flats below 13 and sharps above 19, seven to an alteration.
            alteration = Int((Double(tpc + 1) / 7).rounded(.down)) - 2
            let natural = tpc - 7 * alteration
            step = Self.stepOfNatural[min(max(natural - 13, 0), 6)]
            let octave = Int((Double(pitch - alteration - Self.semitoneOfStep[step]) / 12).rounded(.down))
            line = octave * 7 + step
        }

        /// The step (C = 0 … B = 6) of the natural tpcs 13 … 19.
        private static let stepOfNatural = [3, 0, 4, 1, 5, 2, 6]
        private static let semitoneOfStep = [0, 2, 4, 5, 7, 9, 11]
    }

    /// The alteration a key of `fifths` gives a step (C = 0 … B = 6): sharps on F C G D A E B, flats on B E A D G C F.
    private static func keyAlteration(step: Int, fifths: Int) -> Int {
        let sharps = [3, 0, 4, 1, 5, 2, 6]
        if fifths > 0 { return sharps.prefix(min(fifths, 7)).contains(step) ? 1 : 0 }
        if fifths < 0 { return sharps.reversed().prefix(min(-fifths, 7)).contains(step) ? -1 : 0 }
        return 0
    }

    /// The sharp, flat or natural that writes `alteration`; nil for any other.
    private static func plainAccidental(_ alteration: Int) -> Accidental? {
        switch alteration {
        case -1: .flat
        case 0: .natural
        case 1: .sharp
        default: nil
        }
    }
}
