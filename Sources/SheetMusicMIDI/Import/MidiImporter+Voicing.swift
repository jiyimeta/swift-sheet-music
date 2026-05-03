import Foundation
import SheetMusicCore

// MARK: - VoiceNote

/// Minimal note span used internally by the voicing pass.
private struct VoiceNote {
    var onTick: Int
    var offTick: Int
    var pitch: Int
    /// True when the note is a continuation from a prior bar (carryIn).
    var startsTied: Bool = false
    /// True when the note continues into the next bar (carryOut).
    var endsTied: Bool = false
}

// MARK: - GM drum-kit notehead table

extension MidiImporter {
    /// GM drum-kit pitch → notehead shape. Pitches not listed get
    /// `nil` (which the renderer interprets as the default head).
    fileprivate static let gmDrumHeads: [Int: String] = [
        35: "normal", // acoustic bass drum
        36: "normal", // bass drum 1
        38: "normal", // acoustic snare
        40: "normal", // electric snare
        42: "cross", // closed hi-hat
        44: "cross", // pedal hi-hat
        46: "cross", // open hi-hat
        49: "diamond", // crash cymbal 1
        51: "diamond", // ride cymbal 1
        57: "diamond", // crash cymbal 2
        59: "diamond", // ride cymbal 2
    ]
}

// MARK: - voice()

extension MidiImporter {
    /// Produce a `Voice` from a quantized measure plus the original
    /// `ImportMeasure` (which carries the noteOn/noteOff stream
    /// needed to drive sustained-pitch tracking).
    ///
    /// The `quantized` argument carries tuplet ranges (which we
    /// re-attach to the resulting voice). The actual element list
    /// is rebuilt here from the original event stream so we can
    /// generate `tieForward` / `tieBack` markers correctly across
    /// staggered noteOffs and bar boundaries.
    static func voice(
        quantized: QuantizedMeasure,
        measure: ImportMeasure,
        division: Int,
        isDrumTrack: Bool = false,
        concertKey: Int = 0
    ) -> Voice {
        var notes = collectNotes(from: measure)
        mergeCarryIns(into: &notes, measure: measure)
        mergeCarryOuts(into: &notes, measure: measure)

        notes = snapVoiceNotesToGrid(notes, quantized: quantized)

        let grid = Set(notes.flatMap { [$0.onTick, $0.offTick] })
            .union([measure.startTick, measure.endTick])
            .sorted()

        var elements: [VoiceElement] = []
        var elementTicks: [Int] = [] // start tick of each element in the rebuilt list
        var prev = measure.startTick
        // Per-measure persistence of explicit accidentals: key =
        // packed (letter, octave). Reset for each `voice()` call so
        // accidentals correctly clear at bar lines.
        var persistentAlters: [Int: Int] = [:]

        for tick in grid where tick > prev {
            var coreNotes = buildChordNotes(
                at: prev, until: tick, notes: notes,
                isDrumTrack: isDrumTrack, concertKey: concertKey
            )
            if !isDrumTrack {
                for i in coreNotes.indices {
                    applyAccidental(
                        &coreNotes[i],
                        concertKey: concertKey,
                        persistentAlters: &persistentAlters
                    )
                }
            }
            let duration = exactDuration(ticks: tick - prev, division: division)
            elementTicks.append(prev)
            elements.append(.chord(Chord(duration: duration, notes: ChordNotes(coreNotes))))
            prev = tick
        }

        // Re-resolve tuplet indices from tick ranges into the rebuilt element list.
        let resolvedTuplets = zip(quantized.tuplets, quantized.tupletTickRanges)
            .compactMap { tuplet, tickRange -> Tuplet? in
                guard let startIndex = elementTicks.firstIndex(where: { tickRange.contains($0) })
                else { return nil }
                guard let endIndex = elementTicks.lastIndex(where: { tickRange.contains($0) })
                else { return nil }
                return Tuplet(
                    normalNotes: tuplet.normalNotes,
                    actualNotes: tuplet.actualNotes,
                    startIndex: startIndex,
                    endIndex: endIndex
                )
            }

        return Voice(elements: elements, tuplets: resolvedTuplets)
    }
}

// MARK: - Private helpers

extension MidiImporter {
    /// Collect `(onTick, offTick, pitch)` triples from the measure's event stream.
    private static func collectNotes(from measure: ImportMeasure) -> [VoiceNote] {
        var open: [(channel: Int, pitch: Int, onTick: Int)] = []
        var notes: [VoiceNote] = []
        for ev in measure.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append((c, p, ev.tick))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let i = open.firstIndex(where: { $0.channel == c && $0.pitch == p }) {
                    let n = open.remove(at: i)
                    notes.append(VoiceNote(onTick: n.onTick, offTick: ev.tick, pitch: p))
                }
            default: break
            }
        }
        for n in open {
            notes.append(VoiceNote(onTick: n.onTick, offTick: measure.endTick, pitch: n.pitch))
        }
        return notes
    }

    /// Snap each VoiceNote's on/off ticks to the same grid the
    /// quantizer chose (binary or tuplet) so chord gaps land on
    /// standard note values. Without this voice() would walk raw
    /// event ticks, and any drift from the grid (typical in
    /// DAW-exported MIDI) would produce `.fraction` durations that
    /// downstream layout can't render as notation.
    /// After snapping, drops any zero-length notes (where on == off).
    private static func snapVoiceNotesToGrid(
        _ notes: [VoiceNote],
        quantized: QuantizedMeasure
    ) -> [VoiceNote] {
        notes.map { n in
            VoiceNote(
                onTick: snapToQuantizedGrid(
                    n.onTick,
                    assignments: quantized.assignments,
                    fallbackGrid: quantized.binaryGrid
                ),
                offTick: snapToQuantizedGrid(
                    n.offTick,
                    assignments: quantized.assignments,
                    fallbackGrid: quantized.binaryGrid
                ),
                pitch: n.pitch,
                startsTied: n.startsTied,
                endsTied: n.endsTied
            )
        }
        .filter { $0.onTick < $0.offTick }
    }

    /// Synthesise a `startsTied` VoiceNote at the measure head for each carryIn.
    private static func mergeCarryIns(into notes: inout [VoiceNote], measure: ImportMeasure) {
        for carried in measure.carryIns {
            notes.append(VoiceNote(
                onTick: measure.startTick,
                offTick: min(carried.noteOffTick, measure.endTick),
                pitch: carried.pitch,
                startsTied: true
            ))
        }
    }

    /// Mark the matching VoiceNote `endsTied` for each carryOut, synthesising
    /// one if the noteOn did not fall within this measure.
    private static func mergeCarryOuts(into notes: inout [VoiceNote], measure: ImportMeasure) {
        for carried in measure.carryOuts {
            let onTick = max(carried.noteOnTick, measure.startTick)
            if let idx = notes.firstIndex(where: { $0.pitch == carried.pitch && $0.onTick == onTick }) {
                notes[idx].endsTied = true
                notes[idx].offTick = measure.endTick
            } else {
                notes.append(VoiceNote(
                    onTick: onTick,
                    offTick: measure.endTick,
                    pitch: carried.pitch,
                    endsTied: true
                ))
            }
        }
    }

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
        // MuseScore line of fifths centered on D (16):
        //   F=13, C=14, G=15, D=16, A=17, E=18, B=19.
        // Sharp = +7 along the line; flat = -7. Concretely:
        //   sharps: F#=20, C#=21, G#=22, D#=23, A#=24
        //   flats:  Gb=8, Db=9, Ab=10, Eb=11, Bb=12
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

    /// Build the per-pitch `Note` array for a single chord step
    /// (gap from `prev` to `tick`).
    private static func buildChordNotes(
        at prev: Int,
        until tick: Int,
        notes: [VoiceNote],
        isDrumTrack: Bool,
        concertKey: Int
    ) -> [SheetMusicCore.Note] {
        let activeNotes = notes.filter { $0.onTick <= prev && $0.offTick > prev }
        let willContinue = notes.filter { $0.onTick <= prev && $0.offTick > tick }.map(\.pitch)
        let comesFromPrior = notes.filter { $0.onTick < prev && $0.offTick > prev }.map(\.pitch)
        return activeNotes.map(\.pitch).map { pitch in
            buildNote(
                pitch: pitch,
                prev: prev,
                tick: tick,
                activeNotes: activeNotes,
                comesFromPrior: comesFromPrior,
                willContinue: willContinue,
                isDrum: isDrumTrack,
                concertKey: concertKey
            )
        }
    }

    /// Decompose a (pitch, tpc) pair into (diatonic letter index 0..6
    /// in C-major order, alter -2..+2, octave). Mirrors
    /// `PitchStaffPosition.octaveFor` so the B/C boundary works for
    /// enharmonic spellings (B♯3 = MIDI 60, C♭5 = MIDI 59, etc.).
    static func letterAlterOctave(
        pitch: Int, tpc: Int
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
    private static func applyAccidental(
        _ note: inout SheetMusicCore.Note,
        concertKey: Int,
        persistentAlters: inout [Int: Int]
    ) {
        let (letter, alter, octave) = letterAlterOctave(pitch: note.pitch, tpc: note.tpc)
        let key = letter * 32 + (octave + 16) // pack (letter, octave) — handles negative octaves
        let currentAlter = persistentAlters[key] ?? keySigAlter(letter: letter, concertKey: concertKey)
        if alter != currentAlter {
            note.accidental = accidentalFor(alter: alter)
            persistentAlters[key] = alter
        }
    }

    /// Stamp tie flags (and, for drum tracks, a notehead shape) on a
    /// single note within the chord-emission loop.
    private static func buildNote(
        pitch: Int,
        prev: Int,
        tick: Int,
        activeNotes: [VoiceNote],
        comesFromPrior: [Int],
        willContinue: [Int],
        isDrum: Bool = false,
        concertKey: Int = 0
    ) -> SheetMusicCore.Note {
        var n = SheetMusicCore.Note(
            pitch: pitch,
            tpc: tpc(forMidiPitch: pitch, concertKey: concertKey)
        )
        if comesFromPrior.contains(pitch) { n.tieBack = 1 }
        if activeNotes.contains(where: { $0.pitch == pitch && $0.startsTied && $0.onTick == prev }) {
            n.tieBack = 1
        }
        if willContinue.contains(pitch) { n.tieForward = 1 }
        if activeNotes.contains(where: { $0.pitch == pitch && $0.endsTied && $0.offTick == tick }) {
            n.tieForward = 1
        }
        if isDrum { n.headType = gmDrumHeads[pitch] }
        return n
    }
}
