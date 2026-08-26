import SheetMusicCore
import SheetMusicFoundation

// `VoiceNote` and the passes that gather / merge / snap them live in
// `MidiImporter+VoiceNotes.swift`.

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
        concertKey: Int = 0,
        maxDots: Int = 1,
    ) -> Voice {
        var notes = collectNotes(from: measure)
        mergeCarryIns(into: &notes, measure: measure)
        mergeCarryOuts(into: &notes, measure: measure)

        notes = snapVoiceNotesToGrid(notes, quantized: quantized)

        // Include tuplet range edges so the chord-emission walk
        // never spans a tuplet boundary. Without these, a held note
        // crossing into a tuplet would emit a binary-decomposed
        // chord whose later parts fall inside the tuplet range
        // (and get wrapped by `resolvedTuplets`), but with stored
        // durations whose un-scaled form (× actual/normal) is not
        // a named base + dots — `MSCXEncoder` then refuses them.
        let tupletEdges = quantized.tupletTickRanges
            .flatMap { [$0.lowerBound, $0.upperBound] }
        let grid = Set(notes.flatMap { [$0.onTick, $0.offTick] })
            .union([measure.startTick, measure.endTick])
            .union(tupletEdges)
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
                maxDots: maxDots,
                persistentAlters: &persistentAlters,
                elements: &elements,
                elementTicks: &elementTicks,
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
                    endIndex: endIndex,
                )
            }

        return Voice(elements: elements, tuplets: resolvedTuplets)
    }
}

// MARK: - Private helpers

extension MidiImporter {
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
        maxDots: Int,
        persistentAlters: inout [Int: Int],
        elements: inout [VoiceElement],
        elementTicks: inout [Int],
    ) {
        var coreNotes = buildChordNotes(
            at: prev, until: tick, notes: notes,
            isDrumTrack: isDrumTrack, concertKey: concertKey,
        )
        if !isDrumTrack {
            for i in coreNotes.indices {
                applyAccidental(
                    &coreNotes[i],
                    concertKey: concertKey,
                    persistentAlters: &persistentAlters,
                )
            }
        }
        let durations: [NoteDuration]
        if let tupletIdx = quantized.tupletTickRanges.firstIndex(where: { $0.contains(prev) }) {
            let tuplet = quantized.tuplets[tupletIdx]
            let tupletStart = quantized.tupletTickRanges[tupletIdx].lowerBound
            durations = tupletDurations(
                gap: tick - prev,
                actualNotes: tuplet.actualNotes,
                normalNotes: tuplet.normalNotes,
                division: division,
                offsetInTuplet: prev - tupletStart,
                maxDots: coreNotes.isEmpty ? 0 : maxDots,
            )
        } else {
            durations = decomposeIntoStandardDurations(
                ticks: tick - prev,
                division: division,
                offsetInMeasure: prev - measure.startTick,
                maxDots: coreNotes.isEmpty ? 0 : maxDots,
            )
        }
        appendChordParts(
            durations: durations,
            coreNotes: coreNotes,
            startTick: prev,
            division: division,
            elements: &elements,
            elementTicks: &elementTicks,
        )
    }

    /// Decompose a played tick gap inside a tuplet into stored
    /// `NoteDuration` parts whose un-scaled (notated) values are
    /// representable as a named base + dots (the form
    /// `MSCXEncoder` requires).
    ///
    /// Inside a tuplet of ratio actual:normal, the encoder un-scales
    /// `stored × actual/normal` to recover the notated duration. So
    /// `stored` must equal `notated.asFraction × normal/actual` for
    /// some notated duration that decomposes. A single chord that
    /// spans multiple tuplet slots may not match any single named
    /// duration after un-scaling (e.g. 5/8 from a 5:4 quintuplet
    /// half), and must be split into tied parts whose notated
    /// durations each decompose.
    ///
    /// Strategy: convert the played gap to "notated ticks"
    /// (gap × actual/normal), reuse `decomposeIntoStandardDurations`
    /// to split that into named durations, then back-scale each
    /// resulting duration by `× normal/actual` so the stored Voice
    /// reflects played time.
    private static func tupletDurations(
        gap: Int,
        actualNotes: Int,
        normalNotes: Int,
        division: Int,
        offsetInTuplet: Int,
        maxDots: Int,
    ) -> [NoteDuration] {
        let notatedTicks = gap * actualNotes / normalNotes
        let notatedOffset = offsetInTuplet * actualNotes / normalNotes
        let parts = decomposeIntoStandardDurations(
            ticks: notatedTicks,
            division: division,
            offsetInMeasure: notatedOffset,
            maxDots: maxDots,
        )
        return parts.map { notated in
            let f = notated.asFraction
            return .fraction(Fraction(
                numerator: f.numerator * normalNotes,
                denominator: f.denominator * actualNotes,
            ))
        }
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
        elementTicks: inout [Int],
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
        concertKey: Int,
    ) -> [SheetMusicCore.Note] {
        let activeNotes = notes.filter { $0.onTick <= prev && $0.offTick > prev }
        let willContinue = notes.filter { $0.onTick <= prev && $0.offTick > tick }.map(\.pitch)
        let comesFromPrior = notes.filter { $0.onTick < prev && $0.offTick > prev }.map(\.pitch)
        return activeNotes.map { active in
            buildNote(
                pitch: active.pitch,
                velocity: active.velocity,
                prev: prev,
                tick: tick,
                activeNotes: activeNotes,
                comesFromPrior: comesFromPrior,
                willContinue: willContinue,
                isDrum: isDrumTrack,
                concertKey: concertKey,
            )
        }
    }

    /// Stamp tie flags (and, for drum tracks, a notehead shape) on a
    /// single note within the chord-emission loop.
    ///
    /// The recorded noteOn velocity becomes an absolute per-note
    /// override (`Note.userVelocity` with the default `.user` type),
    /// mirroring `setMusicNotesFromMidi` in MuseScore's MIDI importer.
    /// The import path emits no `Dynamic`s, so without this every note
    /// of an imported performance would flatten to the score's default
    /// mezzo-forte. A velocity of 0 never reaches here — that spelling
    /// of noteOn is a release, and `collectNotes` treats it as one.
    private static func buildNote( // swiftlint:disable:this function_parameter_count
        pitch: Int,
        velocity: Int,
        prev: Int,
        tick: Int,
        activeNotes: [VoiceNote],
        comesFromPrior: [Int],
        willContinue: [Int],
        isDrum: Bool = false,
        concertKey: Int = 0,
    ) -> SheetMusicCore.Note {
        var n = SheetMusicCore.Note(
            pitch: pitch,
            tpc: tpc(forMidiPitch: pitch, concertKey: concertKey),
            userVelocity: velocity,
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
