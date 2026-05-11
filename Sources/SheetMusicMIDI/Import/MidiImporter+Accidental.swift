import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Tonal pitch class for a MIDI pitch, given an optional key
    /// signature for context.
    ///
    /// White keys always take the natural TPC (any chromatic
    /// alteration is rendered as an accidental on top of the key
    /// signature). Black keys take the spelling that matches the
    /// key's direction:
    ///   - sharp keys (concertKey ≥ 0) → C# / D# / F# / G# / A#
    ///   - flat keys  (concertKey < 0) → Db / Eb / Gb / Ab / Bb
    ///
    /// MuseScore TPC convention: F=13, C=14, G=15, D=16, A=17,
    /// E=18, B=19 along the line of fifths; +7 = sharp, -7 = flat.
    static func tpc(forMidiPitch midiPitch: Int, concertKey: Int = 0) -> Int {
        let pitchClass = ((midiPitch % 12) + 12) % 12
        let preferFlats = concertKey < 0
        switch pitchClass {
        case 0: return 14 // C
        case 1: return preferFlats ? 9 : 21 // Db / C#
        case 2: return 16 // D
        case 3: return preferFlats ? 11 : 23 // Eb / D#
        case 4: return 18 // E
        case 5: return 13 // F
        case 6: return preferFlats ? 8 : 20 // Gb / F#
        case 7: return 15 // G
        case 8: return preferFlats ? 10 : 22 // Ab / G#
        case 9: return 17 // A
        case 10: return preferFlats ? 12 : 24 // Bb / A#
        case 11: return 19 // B
        default: return 14
        }
    }

    /// Decompose a (pitch, tpc) pair into (diatonic letter index 0..6
    /// in C-major order, alter -2..+2, octave). Mirrors
    /// `PitchStaffPosition.octaveFor` so the B/C boundary works for
    /// enharmonic spellings (B♯3 = MIDI 60, C♭5 = MIDI 59, etc.).
    static func letterAlterOctave(
        pitch: Int, tpc: Int,
    ) -> (letter: Int, alter: Int, octave: Int) {
        let tpcLetters: [Int] = [3, 0, 4, 1, 5, 2, 6] // F C G D A E B → C-letter index
        let letter = tpcLetters[((tpc + 1) % 7 + 7) % 7]
        let naturalTpc: [Int] = [14, 16, 18, 13, 15, 17, 19] // C D E F G A B
        let alter = (tpc - naturalTpc[letter]) / 7
        let letterSemitone: [Int] = [0, 2, 4, 5, 7, 9, 11] // C D E F G A B
        let naiveOctave = pitch / 12 - 1
        let naiveSemitone = pitch - 12 * (naiveOctave + 1)
        let diff = naiveSemitone - letterSemitone[letter]
        let octave: Int
        if diff >= 6 {
            octave = naiveOctave + 1
        } else if diff <= -6 {
            octave = naiveOctave - 1
        } else {
            octave = naiveOctave
        }
        return (letter, alter, octave)
    }

    /// Diatonic alter (-1, 0, +1) implied by the key signature for a
    /// given letter index (0=C, 1=D, …, 6=B).
    static func keySigAlter(letter: Int, concertKey: Int) -> Int {
        // Sharps cycle of fifths: F C G D A E B (letter indices 3 0 4 1 5 2 6).
        // Flats reverse:           B E A D G C F (letter indices 6 2 5 1 4 0 3).
        let sharpOrder = [3, 0, 4, 1, 5, 2, 6]
        let flatOrder = [6, 2, 5, 1, 4, 0, 3]
        if concertKey > 0 {
            let n = min(concertKey, 7)
            if sharpOrder.prefix(n).contains(letter) { return 1 }
        } else if concertKey < 0 {
            let n = min(-concertKey, 7)
            if flatOrder.prefix(n).contains(letter) { return -1 }
        }
        return 0
    }

    /// Map an alter integer to the matching `Accidental`. Returns
    /// nil for `alter` values outside the supported range.
    static func accidentalFor(alter: Int) -> Accidental? {
        switch alter {
        case -2: .doubleFlat
        case -1: .flat
        case 0: .natural
        case 1: .sharp
        case 2: .doubleSharp
        default: nil
        }
    }

    /// If `note`'s alter differs from what's currently in force at
    /// its (letter, octave) under the given key signature plus any
    /// earlier accidental in the same measure, stamp the visual
    /// accidental and update the tracking state.
    static func applyAccidental(
        _ note: inout SheetMusicCore.Note,
        concertKey: Int,
        persistentAlters: inout [Int: Int],
    ) {
        let (letter, alter, octave) = letterAlterOctave(pitch: note.pitch, tpc: note.tpc)
        let key = letter * 32 + (octave + 16) // pack (letter, octave) — handles negative octaves
        let currentAlter = persistentAlters[key] ?? keySigAlter(letter: letter, concertKey: concertKey)
        if alter != currentAlter {
            note.accidental = accidentalFor(alter: alter)
            persistentAlters[key] = alter
        }
    }
}
