import SheetMusicFoundation

/// Diatonic (staff-line/space) pitch math for the notehead drag gesture. One staff step = one diatonic letter step.
/// The result is spelled IN KEY: the tpc for a letter under concert key K (−7…+7) is the unique value ≡ the letter's
/// natural tpc (mod 7) lying in 13+K ... 19+K (naturals occupy 13…19 at K = 0; each sharp shifts the window up by
/// one, each flat down by one).
public enum StaffStepPitch {
    /// TPC of each natural letter, `C D E F G A B` order.
    private static let naturalTpcByLetter = [14, 16, 18, 13, 15, 17, 19]
    /// Semitone offset of each natural letter from C, `C D E F G A B` order.
    private static let naturalSemitoneByLetter = [0, 2, 4, 5, 7, 9, 11]

    /// Diatonic letter index (0=C … 6=B) of a TPC. `(tpc + 1) % 7` rotates the line of fifths to align with
    /// `F C G D A E B`; the table maps that rotation back to `C D E F G A B` order.
    private static func letterIndex(forTpc tpc: Int) -> Int {
        let table = [3, 0, 4, 1, 5, 2, 6]
        return table[((tpc + 1) % 7 + 7) % 7]
    }

    /// steps > 0 = up. nil when the result leaves MIDI 0…127.
    public static func diatonicShift(from note: Note, bySteps steps: Int, keySig: Int) -> (pitch: Int, tpc: Int)? {
        let letter = letterIndex(forTpc: note.tpc)
        let naturalSemi = naturalSemitoneByLetter[letter]
        // The octave bucket the note is currently written in: the multiple of 12 that places this letter's
        // natural pitch closest to the note's actual (possibly altered) pitch.
        let octaveIndex = Int(((Double(note.pitch) - Double(naturalSemi)) / 12).rounded())

        let rawLetter = letter + steps
        let newLetter = ((rawLetter % 7) + 7) % 7
        let octaveCarry = Int((Double(rawLetter) / 7).rounded(.down))

        let newNaturalTpc = naturalTpcByLetter[newLetter]
        let newTpc = inKeyTpc(naturalTpc: newNaturalTpc, keySig: keySig)
        let alteration = (newTpc - newNaturalTpc) / 7
        let newNaturalSemi = naturalSemitoneByLetter[newLetter]
        let newPitch = 12 * (octaveIndex + octaveCarry) + newNaturalSemi + alteration

        guard (0 ... 127).contains(newPitch) else { return nil }
        return (newPitch, newTpc)
    }

    /// tpc ≡ naturalTpc (mod 7), shifted into the window `13+keySig ... 19+keySig`.
    public static func inKeyTpc(naturalTpc: Int, keySig: Int) -> Int {
        let low = 13 + keySig
        let offset = ((naturalTpc - low) % 7 + 7) % 7
        return low + offset
    }
}
