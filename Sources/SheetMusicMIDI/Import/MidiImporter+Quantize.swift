import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Quantize a single measure's onsets. Walks candidate spans
    /// (whole measure, halves, quarters, half-beats) largest-first.
    /// For each span, tries a binary grid first; if onsets don't fit
    /// the binary grid, tries each tuplet ratio in `options.tupletRatios`
    /// (e.g. 3:2 for triplet). Spans where neither fits cascade into
    /// finer subdivisions. The final assembly emits a flat element
    /// list of chords plus tuplet ranges referencing element indices.
    static func quantize(
        measure: ImportMeasure,
        division: Int,
        options: MidiImportOptions
    ) -> QuantizedMeasure {
        let tolerance = options.onsetTolerance ?? max(division / 16, 1)
        let onsets = noteOnTicks(in: measure)
        let spans = candidateSpans(measure: measure, division: division)
        var assignments: [TupletAssignment] = []
        _ = fitSpanList(
            spans: spans,
            onsets: onsets,
            grid: options.quantizeGrid.ticks(division: division),
            tolerance: tolerance,
            tupletRatios: options.tupletRatios,
            assignments: &assignments
        )
        return assemble(
            measure: measure,
            assignments: assignments,
            division: division
        )
    }

    struct TupletAssignment {
        var range: Range<Int> // tick range of the span
        var ratio: TupletRatio? // nil → binary fit
        var grid: Int // tick step within the span
    }

    static func candidateSpans(measure: ImportMeasure, division: Int) -> [Range<Int>] {
        // Power-of-two splits anchored at measure.startTick. Yields
        // [whole measure, halves, quarters, half-beats]. Subdivisions
        // that don't divide the time signature cleanly are skipped.
        var spans: [Range<Int>] = []
        let measureLen = measure.endTick - measure.startTick
        let beat = (division * 4) / measure.timeSignature.denominator
        let beats = measure.timeSignature.numerator
        let halfBeat = max(beat / 2, 1)

        for divisor in [1, 2, 4, beats, beats * 2] {
            if divisor < 1 { continue }
            if measureLen % divisor != 0 { continue }
            let span = measureLen / divisor
            if span < halfBeat { continue }
            for i in 0 ..< divisor {
                let start = measure.startTick + i * span
                spans.append(start ..< (start + span))
            }
        }
        // Dedupe while preserving order: prefer the largest spans
        // first so they get tried before their subdivisions.
        var seen: Set<Range<Int>> = []
        return spans.filter { seen.insert($0).inserted }
            .sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }
    }

    /// Walk spans largest-first. For each, try to fit *all onsets
    /// inside that span* on a binary or tuplet grid. On success,
    /// record an assignment and remove the covered span from
    /// subsequent attempts.
    static func fitSpanList(
        spans: [Range<Int>],
        onsets: [Int],
        grid: Int,
        tolerance: Int,
        tupletRatios: [TupletRatio],
        assignments: inout [TupletAssignment]
    ) -> Bool {
        var covered: [Range<Int>] = []
        for span in spans {
            // Skip spans already inside a covered range.
            if covered.contains(where: { $0.contains(span.lowerBound) }) { continue }
            let inSpan = onsets.filter { span.contains($0) }
            if inSpan.isEmpty { continue }

            if fitsBinary(onsets: inSpan, span: span, grid: grid, tolerance: tolerance) {
                assignments.append(TupletAssignment(range: span, ratio: nil, grid: grid))
                covered.append(span)
                continue
            }
            if let ratio = tupletRatios.first(where: { ratio in
                fitsTuplet(onsets: inSpan, span: span, ratio: ratio, tolerance: tolerance)
            }) {
                let unit = (span.upperBound - span.lowerBound) / ratio.actual
                assignments.append(TupletAssignment(range: span, ratio: ratio, grid: unit))
                covered.append(span)
            }
        }
        return !assignments.isEmpty
    }

    static func fitsBinary(
        onsets: [Int], span: Range<Int>, grid: Int, tolerance: Int
    ) -> Bool {
        guard grid > 0 else { return false }
        return onsets.allSatisfy { onset in
            let offset = onset - span.lowerBound
            let mod = offset % grid
            return min(mod, grid - mod) <= tolerance
        }
    }

    static func fitsTuplet(
        onsets: [Int], span: Range<Int>, ratio: TupletRatio, tolerance: Int
    ) -> Bool {
        let unit = (span.upperBound - span.lowerBound) / ratio.actual
        guard unit > 0 else { return false }
        return onsets.allSatisfy { onset in
            let offset = onset - span.lowerBound
            let mod = offset % unit
            return min(mod, unit - mod) <= tolerance
        }
    }

    static func noteOnTicks(in measure: ImportMeasure) -> [Int] {
        measure.events.compactMap { ev -> Int? in
            if case let .noteOn(_, _, v) = ev.event, v > 0 { return ev.tick }
            return nil
        }.sorted()
    }

    static func noteOnPitches(at tick: Int, in measure: ImportMeasure) -> [Int] {
        measure.events.compactMap { ev -> Int? in
            if case let .noteOn(_, p, v) = ev.event, v > 0, ev.tick == tick {
                return p
            }
            return nil
        }
    }

    static func snapTick(_ tick: Int, assignments: [TupletAssignment]) -> Int {
        guard let owning = assignments.first(where: { $0.range.contains(tick) }) else {
            return tick
        }
        let offset = tick - owning.range.lowerBound
        let nearest = ((offset + owning.grid / 2) / owning.grid) * owning.grid
        return owning.range.lowerBound + nearest
    }

    static func snap(
        onsets: [Int],
        assignments: [TupletAssignment],
        measure: ImportMeasure,
        division: Int
    ) -> [(tick: Int, pitches: [Int])] {
        var grouped: [Int: [Int]] = [:]
        for tick in onsets {
            let snapped = snapTick(tick, assignments: assignments)
            grouped[snapped, default: []]
                .append(contentsOf: noteOnPitches(at: tick, in: measure))
        }
        return grouped.keys.sorted().map { (tick: $0, pitches: grouped[$0] ?? []) }
    }

    static func durationFor(
        gap: Int,
        at tick: Int,
        assignments: [TupletAssignment],
        division: Int
    ) -> NoteDuration {
        // Inside a tuplet, the *written* duration corresponds to
        // gap × actual / normal (the renderer scales it back).
        if let owning = assignments.first(where: { $0.ratio != nil && $0.range.contains(tick) }),
           let ratio = owning.ratio
        {
            let written = (gap * ratio.actual) / ratio.normal
            return nearestDuration(ticks: written, division: division)
        }
        return nearestDuration(ticks: gap, division: division)
    }

    static func nearestDuration(ticks: Int, division: Int) -> NoteDuration {
        let candidates: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond,
        ]
        var best = NoteDuration.sixteenth
        var bestDelta = Int.max
        for c in candidates {
            let delta = abs(c.ticks(division: division) - ticks)
            if delta < bestDelta { bestDelta = delta; best = c }
        }
        return best
    }

    struct PendingTuplet {
        var startElement: Int
        var ratio: TupletRatio
        var tickRange: Range<Int>
    }

    static func assemble(
        measure: ImportMeasure,
        assignments: [TupletAssignment],
        division: Int
    ) -> QuantizedMeasure {
        let snappedOnsets = snap(
            onsets: noteOnTicks(in: measure),
            assignments: assignments,
            measure: measure,
            division: division
        )

        var elements: [VoiceElement] = []
        var tupletEntries: [(elementRange: ClosedRange<Int>, ratio: TupletRatio, tickRange: Range<Int>)] = []
        var prev = measure.startTick
        var inProgress: PendingTuplet?

        let allTicks = (snappedOnsets.map(\.tick) + [measure.endTick]).sorted()
        for tick in allTicks where tick > prev {
            let gap = tick - prev
            let duration = durationFor(
                gap: gap, at: prev, assignments: assignments, division: division
            )
            let pitches = snappedOnsets.first(where: { $0.tick == prev })?.pitches ?? []
            let notes = ChordNotes(pitches.map { Note(pitch: $0, tpc: 0) })
            elements.append(.chord(Chord(duration: duration, notes: notes)))

            // Track tuplet element-range membership.
            let owningTuplet = assignments.first(where: {
                $0.ratio != nil && $0.range.contains(prev)
            })
            if let owning = owningTuplet, let owningRatio = owning.ratio,
               inProgress?.tickRange != owning.range
            {
                if let pending = inProgress {
                    let r = pending.startElement ... (elements.count - 2)
                    tupletEntries.append((r, pending.ratio, pending.tickRange))
                }
                inProgress = PendingTuplet(
                    startElement: elements.count - 1,
                    ratio: owningRatio,
                    tickRange: owning.range
                )
            } else if owningTuplet == nil, let pending = inProgress {
                let r = pending.startElement ... (elements.count - 2)
                tupletEntries.append((r, pending.ratio, pending.tickRange))
                inProgress = nil
            }
            prev = tick
        }
        if let pending = inProgress {
            let r = pending.startElement ... (elements.count - 1)
            tupletEntries.append((r, pending.ratio, pending.tickRange))
        }

        let tuplets = tupletEntries.map {
            Tuplet(
                normalNotes: $0.ratio.normal,
                actualNotes: $0.ratio.actual,
                startIndex: $0.elementRange.lowerBound,
                endIndex: $0.elementRange.upperBound
            )
        }
        return QuantizedMeasure(
            elements: elements,
            tuplets: tuplets,
            tupletTickRanges: tupletEntries.map(\.tickRange)
        )
    }
}
