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

        for tick in grid where tick > prev {
            let activeNotes = notes.filter { $0.onTick <= prev && $0.offTick > prev }
            let willContinue = notes.filter { $0.onTick <= prev && $0.offTick > tick }.map(\.pitch)
            let comesFromPrior = notes.filter { $0.onTick < prev && $0.offTick > prev }.map(\.pitch)

            let duration = exactDuration(ticks: tick - prev, division: division)
            let coreNotes: [SheetMusicCore.Note] = activeNotes.map(\.pitch).map { pitch in
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
