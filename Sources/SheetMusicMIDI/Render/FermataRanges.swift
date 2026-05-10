import Foundation
import SheetMusicCore

/// One resolved fermata: the original-tick range its anchor chord/rest
/// occupies, and the hold ratio to apply during that range.
struct FermataRange: Sendable, Equatable {
    let startTick: Int // original (pre-repeat) tick
    let endTick: Int // exclusive
    let stretch: Double // ≥ 1.0; fermata hold multiplier applied to the note duration
}

enum FermataRanges {
    /// Walk every voice, anchor each `.fermata` element to its target
    /// chord/rest, and return the per-staff range list. Deduped on
    /// identical (startTick, endTick) — max stretch wins.
    static func collect(from staff: Staff, division: Int) -> [FermataRange] {
        var ranges: [FermataRange] = []
        var measureBase = 0
        for measure in staff.measures {
            let mTicks = MidiRenderer.measureTicks(
                measure: measure, division: division
            )
            for voice in measure.voices {
                ranges.append(contentsOf: collectInVoice(
                    voice, measureBase: measureBase, division: division
                ))
            }
            measureBase += mTicks
        }
        return dedupeMaxStretch(ranges)
    }

    /// Per-voice anchor walk. Forward search from each fermata for the
    /// next chord/rest in the same voice; if none, fall back to the
    /// most recent prior chord/rest. Drop the fermata when neither
    /// direction yields one.
    private static func collectInVoice(
        _ voice: Voice,
        measureBase: Int,
        division: Int
    ) -> [FermataRange] {
        // Pre-compute each chord's start tick within the voice so both
        // forward and backward searches are O(1) lookups.
        var chordStartTicks: [Int?] = Array(
            repeating: nil, count: voice.elements.count
        )
        var runningTick = measureBase
        for (i, element) in voice.elements.enumerated() {
            switch element {
            case let .chord(chord):
                chordStartTicks[i] = runningTick
                runningTick += chord.duration.ticks(division: division)
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            default:
                break
            }
        }

        var ranges: [FermataRange] = []
        for (i, element) in voice.elements.enumerated() {
            guard case let .fermata(f) = element else { continue }
            let anchor = anchorForFermata(at: i, in: voice, chordStartTicks: chordStartTicks)
            guard let anchor else { continue }
            let chordTicks = anchor.chord.duration.ticks(division: division)
            ranges.append(FermataRange(
                startTick: anchor.startTick,
                endTick: anchor.startTick + chordTicks,
                stretch: f.timeStretch
            ))
        }
        return ranges
    }

    private struct Anchor { let chord: Chord; let startTick: Int }

    private static func anchorForFermata(
        at index: Int,
        in voice: Voice,
        chordStartTicks: [Int?]
    ) -> Anchor? {
        // Forward search.
        for j in (index + 1) ..< voice.elements.count {
            if case let .chord(chord) = voice.elements[j],
               let start = chordStartTicks[j]
            {
                return Anchor(chord: chord, startTick: start)
            }
        }
        // Backward fallback.
        if index > 0 {
            for j in stride(from: index - 1, through: 0, by: -1) {
                if case let .chord(chord) = voice.elements[j],
                   let start = chordStartTicks[j]
                {
                    return Anchor(chord: chord, startTick: start)
                }
            }
        }
        return nil
    }

    private struct DedupeKey: Hashable {
        let startTick: Int
        let endTick: Int
    }

    /// Group by (startTick, endTick); within each group keep the
    /// largest stretch. Returns ranges sorted by startTick then
    /// endTick — required by the sweep-merge consumer.
    private static func dedupeMaxStretch(_ ranges: [FermataRange]) -> [FermataRange] {
        var bestByKey: [DedupeKey: FermataRange] = [:]
        for r in ranges {
            let key = DedupeKey(startTick: r.startTick, endTick: r.endTick)
            if let prev = bestByKey[key], prev.stretch >= r.stretch { continue }
            bestByKey[key] = r
        }
        return bestByKey.values.sorted { lhs, rhs in
            (lhs.startTick, lhs.endTick) < (rhs.startTick, rhs.endTick)
        }
    }
}
