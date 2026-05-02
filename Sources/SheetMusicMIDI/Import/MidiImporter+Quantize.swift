import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Quantize a single measure's onsets to the binary grid. This is
    /// the minimal D1 version — no tuplet detection. D2 extends this
    /// with span-driven recursion and tuplet fit.
    static func quantize(
        measure: ImportMeasure,
        division: Int,
        options: MidiImportOptions
    ) -> QuantizedMeasure {
        let onsets = noteOnTicks(in: measure)
        let snapped = snapBinary(
            onsets: onsets,
            spanStart: measure.startTick,
            grid: options.quantizeGrid.ticks(division: division)
        )
        return buildQuantizedMeasure(
            measure: measure,
            snapped: snapped,
            division: division
        )
    }

    static func noteOnTicks(in measure: ImportMeasure) -> [Int] {
        measure.events.compactMap { ev -> Int? in
            if case let .noteOn(_, _, v) = ev.event, v > 0 { return ev.tick }
            return nil
        }.sorted()
    }

    /// Round each onset to the nearest grid multiple. No tolerance
    /// check — onsets always snap; far-off onsets just incur loss.
    static func snapBinary(onsets: [Int], spanStart: Int, grid: Int) -> [Int] {
        guard grid > 0 else { return onsets }
        return onsets.map { o in
            let offset = o - spanStart
            let nearest = ((offset + grid / 2) / grid) * grid
            return spanStart + nearest
        }
    }

    static func buildQuantizedMeasure(
        measure: ImportMeasure,
        snapped: [Int],
        division: Int
    ) -> QuantizedMeasure {
        var elements: [VoiceElement] = []
        var prev = measure.startTick

        let allTicks = (snapped + [measure.endTick]).sorted()
        for tick in allTicks where tick > prev {
            let gap = tick - prev
            if gap > 0 {
                let duration = nearestDuration(ticks: gap, division: division)
                let pitches = noteOnPitches(at: prev, in: measure)
                let notes = ChordNotes(pitches.map { Note(pitch: $0, tpc: 0) })
                elements.append(.chord(Chord(duration: duration, notes: notes)))
            }
            prev = tick
        }
        return QuantizedMeasure(elements: elements, tuplets: [])
    }

    static func noteOnPitches(at tick: Int, in measure: ImportMeasure) -> [Int] {
        measure.events.compactMap { ev -> Int? in
            if case let .noteOn(_, p, v) = ev.event, v > 0, ev.tick == tick {
                return p
            }
            return nil
        }
    }

    /// Greedy nearest binary duration. D2 extends this for tuplet
    /// scoping; for now simple binary candidates suffice.
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
}
