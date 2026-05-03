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

// MARK: - GM drum-kit tables

extension MidiImporter {
    /// GM drum-kit pitch → notehead shape. The standard
    /// percussion-clef convention uses `cross` for any cymbal /
    /// hi-hat (X notehead) and `normal` for membranophones (kick,
    /// snare, toms, etc.). Pitches not listed get `nil` and render
    /// as the default duration-based notehead.
    static let gmDrumHeads: [Int: String] = [
        // Membranophones (kick / snare / toms / hand-percussion)
        35: "normal", 36: "normal", 37: "normal",
        38: "normal", 39: "normal", 40: "normal",
        41: "normal", 43: "normal", 45: "normal",
        47: "normal", 48: "normal", 50: "normal",
        // Cymbals + hi-hats — cross noteheads
        42: "cross", 44: "cross", 46: "cross",
        49: "cross", 51: "cross", 52: "cross",
        53: "cross", 55: "cross", 57: "cross",
        59: "cross",
        // Cowbell / wood block / etc — triangle to set them apart
        56: "triangle-up", 58: "triangle-up",
        60: "triangle-up", 61: "triangle-up",
    ]

    /// Voice index a given GM drum pitch should belong to in the
    /// engraved drum staff.
    ///   - 0 = voice 1, stems up: cymbals, hi-hats, ride, snare,
    ///         toms (= "hands")
    ///   - 1 = voice 2, stems down: bass drum, low floor tom,
    ///         pedal hi-hat (= "feet")
    /// Matches MuseScore's default drumset partitioning.
    static func gmDrumVoiceIndex(for pitch: Int) -> Int {
        switch pitch {
        case 35, 36, 41, 44: 1
        default: 0
        }
    }

    /// GM drum-kit pitch → percussion-staff line index
    /// (0 = top line, 4 = middle, 8 = bottom line; negative =
    /// above-staff ledger; ≥ 9 = below-staff). Used by the layout
    /// engine via `Instrument.drumLineMap` to place the notehead
    /// at the conventional position for that drum.
    static let gmDrumLines: [Int: Int] = [
        35: 6, // Acoustic Bass Drum (bottom space)
        36: 6, // Bass Drum 1
        37: 2, // Side Stick (3rd line)
        38: 2, // Acoustic Snare (3rd line)
        39: 2, // Hand Clap
        40: 2, // Electric Snare
        41: 8, // Low Floor Tom (bottom line)
        42: -1, // Closed Hi-Hat (above top line)
        43: 7, // High Floor Tom (between bottom space and bottom line)
        44: 9, // Pedal Hi-Hat (below staff)
        45: 5, // Low Tom (4th line)
        46: -1, // Open Hi-Hat (above top line)
        47: 4, // Low-Mid Tom (middle line)
        48: 3, // Hi-Mid Tom
        49: -1, // Crash Cymbal 1 (above top line)
        50: 2, // High Tom
        51: 0, // Ride Cymbal 1 (top line)
        52: -1, // Chinese Cymbal
        53: 0, // Ride Bell
        54: 0, // Tambourine (top line, with diamond head ideally)
        55: -1, // Splash Cymbal
        56: 0, // Cowbell
        57: -1, // Crash Cymbal 2
        58: 1, // Vibraslap
        59: 0, // Ride Cymbal 2
        60: 1, // Hi Bongo
        61: 2, // Low Bongo
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
            emitChordsForGap(
                from: prev, until: tick,
                notes: notes,
                quantized: quantized,
                measure: measure,
                division: division,
                isDrumTrack: isDrumTrack,
                concertKey: concertKey,
                persistentAlters: &persistentAlters,
                elements: &elements,
                elementTicks: &elementTicks
            )
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

    /// Emit one or more chord elements for the gap [from, until)
    /// in the voicing's grid walk: build per-pitch notes, stamp
    /// accidentals if needed, choose duration(s) (single
    /// `.fraction` inside tuplets, decomposed binary parts
    /// elsewhere), and split into multiple tied chords as needed.
    private static func emitChordsForGap(
        from prev: Int,
        until tick: Int,
        notes: [VoiceNote],
        quantized: QuantizedMeasure,
        measure: ImportMeasure,
        division: Int,
        isDrumTrack: Bool,
        concertKey: Int,
        persistentAlters: inout [Int: Int],
        elements: inout [VoiceElement],
        elementTicks: inout [Int]
    ) {
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
        let inTuplet = quantized.tupletTickRanges.contains { $0.contains(prev) }
        let durations: [NoteDuration] = inTuplet
            ? [exactDuration(ticks: tick - prev, division: division)]
            : decomposeIntoStandardDurations(
                ticks: tick - prev,
                division: division,
                offsetInMeasure: prev - measure.startTick,
                allowDot: !coreNotes.isEmpty
            )
        appendChordParts(
            durations: durations,
            coreNotes: coreNotes,
            startTick: prev,
            division: division,
            elements: &elements,
            elementTicks: &elementTicks
        )
    }

    /// Append one or more chord elements covering a single grid
    /// step. When `durations.count > 1`, the chord is split: each
    /// part inherits the same pitches, internal split-points get
    /// matching tieForward/tieBack, and the explicit accidental
    /// only appears on the first part (subsequent tied chords don't
    /// repeat the accidental).
    private static func appendChordParts(
        durations: [NoteDuration],
        coreNotes: [SheetMusicCore.Note],
        startTick: Int,
        division: Int,
        elements: inout [VoiceElement],
        elementTicks: inout [Int]
    ) {
        var partTick = startTick
        for (idx, dur) in durations.enumerated() {
            let isFirst = idx == 0
            let isLast = idx == durations.count - 1
            var partNotes = coreNotes
            for i in partNotes.indices {
                if !isFirst {
                    partNotes[i].tieBack = 1
                    partNotes[i].accidental = nil
                }
                if !isLast {
                    partNotes[i].tieForward = 1
                }
            }
            elementTicks.append(partTick)
            elements.append(.chord(Chord(duration: dur, notes: ChordNotes(partNotes))))
            partTick += dur.ticks(division: division)
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
