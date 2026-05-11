import Foundation
import SheetMusicCore

/// Post-processes a staff's parsed measures to drop `tieForward`/`tieBack`
/// markers that don't connect to the immediately-following chord of the same
/// voice and pitch. Mirrors MuseScore's MusicXML importer, which treats such
/// orphans (the `testUnterminatedTies` fixture's long-distance tie starts) as
/// notational cruft and does not carry them into the Score.
enum TieValidator {
    struct ChordRef {
        let measureIndex: Int
        let voiceIndex: Int
        let elementIndex: Int
        let noteIndex: Int
        let pitch: Int
    }

    static func process(_ staffMeasures: [Measure]) -> [Measure] {
        let chords = flatten(staffMeasures)
        let nextChord = nextChordStartMap(chords)
        var forwardValid = Array(repeating: false, count: chords.count)
        var backValid = Array(repeating: false, count: chords.count)

        var mutable = staffMeasures
        for (i, current) in chords.enumerated() {
            guard
                case let .chord(chord) = mutable[current.measureIndex]
                    .voices[current.voiceIndex]
                    .elements[current.elementIndex],
                    let tieNumber = chord.notes[current.noteIndex].tieForward,
                    let startIdx = nextChord[i]
            else { continue }
            if let matchIdx = findMatch(
                in: chords,
                startingAt: startIdx,
                pitch: current.pitch,
                tieNumber: tieNumber,
                measures: mutable,
            ) {
                forwardValid[i] = true
                backValid[matchIdx] = true
            }
        }

        return applyFilters(chords: chords, forwardValid: forwardValid, backValid: backValid, to: mutable)
    }

    // MARK: - helpers

    private static func flatten(_ measures: [Measure]) -> [ChordRef] {
        var refs: [ChordRef] = []
        for (measureIndex, measure) in measures.enumerated() {
            for (voiceIndex, voice) in measure.voices.enumerated() {
                for (elementIndex, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element else { continue }
                    for (noteIndex, note) in chord.notes.enumerated() {
                        refs.append(ChordRef(
                            measureIndex: measureIndex,
                            voiceIndex: voiceIndex,
                            elementIndex: elementIndex,
                            noteIndex: noteIndex,
                            pitch: note.pitch,
                        ))
                    }
                }
            }
        }
        return refs
    }

    /// For each chord-note flat index, return the flat index of the first note
    /// that lives in the *next* chord of the same voice.
    private static func nextChordStartMap(_ chords: [ChordRef]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for i in 0 ..< chords.count {
            for j in (i + 1) ..< chords.count where chords[j].voiceIndex == chords[i].voiceIndex {
                let differentChord = chords[j].elementIndex != chords[i].elementIndex
                    || chords[j].measureIndex != chords[i].measureIndex
                if differentChord {
                    result[i] = j
                    break
                }
            }
        }
        return result
    }

    private static func findMatch(
        in chords: [ChordRef],
        startingAt startIdx: Int,
        pitch: Int,
        tieNumber: Int,
        measures: [Measure],
    ) -> Int? {
        var j = startIdx
        let startMeasure = chords[startIdx].measureIndex
        let startVoice = chords[startIdx].voiceIndex
        let startElement = chords[startIdx].elementIndex
        while j < chords.count,
              chords[j].measureIndex == startMeasure,
              chords[j].voiceIndex == startVoice,
              chords[j].elementIndex == startElement
        {
            let ref = chords[j]
            if ref.pitch == pitch,
               case let .chord(nextChord) = measures[ref.measureIndex]
                   .voices[ref.voiceIndex]
                   .elements[ref.elementIndex],
                   nextChord.notes[ref.noteIndex].tieBack == tieNumber
            {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func applyFilters(
        chords: [ChordRef],
        forwardValid: [Bool],
        backValid: [Bool],
        to measures: [Measure],
    ) -> [Measure] {
        var out = measures
        for (index, ref) in chords.enumerated() {
            guard case let .chord(chord) = out[ref.measureIndex]
                .voices[ref.voiceIndex]
                .elements[ref.elementIndex] else { continue }
            var updated = chord
            var note = updated.notes[ref.noteIndex]
            if note.tieForward != nil, !forwardValid[index] {
                note.tieForward = nil
            }
            if note.tieBack != nil, !backValid[index] {
                note.tieBack = nil
            }
            updated.notes[ref.noteIndex] = note
            var voice = out[ref.measureIndex].voices[ref.voiceIndex]
            voice.elements[ref.elementIndex] = .chord(updated)
            out[ref.measureIndex].voices[ref.voiceIndex] = voice
        }
        return out
    }
}
