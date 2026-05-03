import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// One measure-play in the unrolled playback order.
    /// `isIterationStart` is true for the first measure of a new repeat iteration
    /// (i.e., immediately after a loop-back). The renderer uses this to re-emit
    /// timeSig and reset tempo to default — matching MuseScore's behaviour of
    /// restarting state at every section boundary.
    struct PlaybackEntry {
        var measureIndex: Int
        var tickOffset: Int
        var isIterationStart: Bool
    }

    /// Build the unrolled playback sequence honouring `<startRepeat>` / `<endRepeat>`
    /// markers and Volta filtering.
    ///
    /// Algorithm:
    ///   - Walk measures left-to-right. Track a `take` counter (1-indexed) that
    ///     increments every time an endRepeat sends us back to the loop start.
    ///   - A measure inside a Volta is played only when `take` matches one of the
    ///     volta's `endings` numbers. Measures with no Volta always play.
    ///   - Each endRepeat with count N triggers a loop-back the first N−1 times we
    ///     reach it (per-position counter). The loop target is the most recent
    ///     `<startRepeat>` (or measure 0 if none).
    static func playbackPlan(for measures: [Measure], division: Int) -> [PlaybackEntry] {
        let measureVoltas = computeMeasureVoltas(measures)
        var plan: [PlaybackEntry] = []
        var tick = 0
        var segmentStart = 0
        var endRepeatHits: [Int: Int] = [:]
        var take = 1
        var index = 0
        // The next measure to be appended marks the start of a new iteration
        // when this is true (set after a loop-back).
        var nextIsIterationStart = false
        // Safety belt — pathological scores shouldn't loop forever.
        var iterations = 0
        let maxIterations = (measures.count + 1) * 16

        while index < measures.count, iterations < maxIterations {
            iterations += 1
            let measure = measures[index]
            if measure.startRepeat {
                segmentStart = index
            }

            let inThisTake: Bool
            if let endings = measureVoltas[index] {
                inThisTake = endings.contains(take)
            } else {
                inThisTake = true
            }
            if inThisTake {
                plan.append(PlaybackEntry(
                    measureIndex: index,
                    tickOffset: tick,
                    isIterationStart: nextIsIterationStart
                ))
                tick += measureTicks(measure: measure, division: division)
                nextIsIterationStart = false
            }

            if let count = measure.endRepeatCount, count > 1 {
                let hits = (endRepeatHits[index] ?? 0) + 1
                endRepeatHits[index] = hits
                if hits < count {
                    take += 1
                    index = segmentStart
                    nextIsIterationStart = true
                    continue
                }
            }
            index += 1
        }
        return plan
    }

    /// Map each measure index to the volta endings (`[Int]`) that apply to it,
    /// or absent if no volta covers it. mscx encodes volta extent as
    /// `<next><location><measures>N</measures>` meaning "ends N measures away";
    /// the volta covers the current measure plus N − 1 additional measures
    /// (so N=1 covers just the anchor measure).
    private static func computeMeasureVoltas(_ measures: [Measure]) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for (i, measure) in measures.enumerated() {
            for voice in measure.voices {
                for element in voice.elements {
                    guard case let .spanner(spanner) = element else { continue }
                    guard spanner.kind == .volta, !spanner.voltaEndings.isEmpty else { continue }
                    let measuresCovered = max(1, spanner.nextMeasuresOffset)
                    for k in 0 ..< measuresCovered where i + k < measures.count {
                        result[i + k] = spanner.voltaEndings
                    }
                }
            }
        }
        return result
    }

    /// Reference duration of a measure in ticks. Uses voice 0; falls back to 4/4
    /// if the measure has no time-bearing elements at all.
    static func measureTicks(measure: Measure, division: Int) -> Int {
        guard let voice = measure.voices.first else { return 4 * division }
        var ticks = 0
        for element in voice.elements {
            switch element {
            case let .chord(chord): ticks += chord.duration.ticks(division: division)
            case let .measureRepeat(rep): ticks += rep.duration.ticks(division: division)
            default: continue
            }
        }
        return ticks
    }

    /// Resolve which notes to play for the given voice index of the given
    /// measure. Returns `nil` only when neither the current measure nor any
    /// referenced source measure has content for this voice.
    ///
    /// MuseScore detects measure-repeat at the **staff** level (`Measure::
    /// isMeasureRepeatGroup(staffIdx)` in `compatmidirenderinternal.cpp:1314`):
    /// when ANY voice of the measure carries the marker, EVERY voice of the
    /// source measure is replayed. We mirror that here by searching all voices
    /// for the marker rather than only the voice we're currently rendering.
    static func resolvedVoice(
        measureIndex: Int,
        staff: Staff,
        voiceIndex: Int
    ) -> Voice? {
        let measure = staff.measures[measureIndex]
        if let rep = explicitMeasureRepeatInAnyVoice(of: measure) {
            return chase(measureIndex: measureIndex - rep.numMeasures, staff: staff, voiceIndex: voiceIndex)
        }
        if let rep = groupRepeatMarker(measureIndex: measureIndex, staff: staff, voiceIndex: voiceIndex) {
            return chase(measureIndex: measureIndex - rep.numMeasures, staff: staff, voiceIndex: voiceIndex)
        }
        if voiceIndex < measure.voices.count {
            return measure.voices[voiceIndex]
        }
        return nil
    }

    /// Find the explicit `<MeasureRepeat>` marker that owns the repeat group
    /// containing `measureIndex`.
    ///
    /// MuseScore stores measure-repeat info in two parts:
    ///   - `<MeasureRepeat><subtype>N</subtype></MeasureRepeat>` (the icon) lives
    ///     on **one** measure inside the repeat group (often the middle of an
    ///     N-measure group).
    ///   - Every measure of the group carries `<measureRepeatCount>K</…>`, where
    ///     K = the measure's 1-based position within the group.
    ///
    /// The group's anchor (its 1st measure) is at `measureIndex − (count − 1)`.
    /// We walk forward from the anchor to find which member carries the marker
    /// — searching ALL voices because MuseScore detects repeat at the staff level.
    static func groupRepeatMarker(
        measureIndex: Int,
        staff: Staff,
        voiceIndex: Int
    ) -> MeasureRepeat? {
        guard let count = staff.measures[measureIndex].measureRepeatCount else { return nil }
        let anchor = measureIndex - (count - 1)
        guard anchor >= 0 else { return nil }
        var i = anchor
        var expectedCount = 1
        while i < staff.measures.count {
            let measure = staff.measures[i]
            guard measure.measureRepeatCount == expectedCount else { break }
            if let rep = explicitMeasureRepeatInAnyVoice(of: measure) {
                return rep
            }
            i += 1
            expectedCount += 1
        }
        return nil
    }

    static func explicitMeasureRepeat(in voice: Voice) -> MeasureRepeat? {
        for element in voice.elements {
            if case let .measureRepeat(rep) = element { return rep }
        }
        return nil
    }

    /// True if any voice of the measure carries a `<MeasureRepeat>` marker —
    /// matches MuseScore's per-staff detection (any track in a staff makes
    /// the whole staff a repeat group for playback).
    static func explicitMeasureRepeatInAnyVoice(of measure: Measure) -> MeasureRepeat? {
        for voice in measure.voices {
            if let rep = explicitMeasureRepeat(in: voice) { return rep }
        }
        return nil
    }

    /// Follow MeasureRepeat chains: if the source is also a repeat measure,
    /// keep walking back until a real measure is found, then strip metadata
    /// (KeySig/TimeSig/Clef) so we don't re-emit signatures the original set.
    static func chase(measureIndex: Int, staff: Staff, voiceIndex: Int) -> Voice {
        var idx = measureIndex
        while idx >= 0 {
            guard voiceIndex < staff.measures[idx].voices.count else {
                idx -= 1; continue
            }
            let candidate = staff.measures[idx].voices[voiceIndex]
            if let rep = explicitMeasureRepeat(in: candidate) {
                idx -= rep.numMeasures
                continue
            }
            if let count = staff.measures[idx].measureRepeatCount, count >= 2 {
                let anchor = idx - (count - 1)
                if anchor >= 0,
                   voiceIndex < staff.measures[anchor].voices.count,
                   let rep = explicitMeasureRepeat(in: staff.measures[anchor].voices[voiceIndex])
                {
                    idx -= rep.numMeasures
                    continue
                }
                idx -= 1
                continue
            }
            let stripped = candidate.elements.filter {
                switch $0 {
                case .chord, .dynamic: true
                default: false
                }
            }
            return Voice(elements: stripped)
        }
        return Voice(elements: [])
    }
}
