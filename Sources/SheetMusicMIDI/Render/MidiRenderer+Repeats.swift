import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// One measure-play in the unrolled playback order.
    /// `isIterationStart` is true for the first measure of a new repeat iteration
    /// (i.e., immediately after a loop-back). The renderer uses this to re-emit
    /// timeSig and reset tempo to default — matching MuseScore's behavior of
    /// restarting state at every section boundary.
    struct PlaybackEntry: Equatable {
        var measureIndex: Int
        var tickOffset: Int
        var isIterationStart: Bool
    }

    /// Build the unrolled playback sequence for ONE staff's measures,
    /// honoring `<startRepeat>` / `<endRepeat>` and volta filtering.
    /// Retained as the single-staff entry point: it delegates to
    /// `RepeatUnwinder` with jumps / markers / section breaks
    /// stripped, because those elements live only on the top staff
    /// and must be handled by the score-global plan
    /// (`MidiRenderer.render(score:)`), never per staff.
    ///
    /// Test-only: a bare measure list carries no tempo lane, so the navigation behind this reads an EMPTY tempo map
    /// and lengthens a breath's pause at 120 BPM. `render(score:)` builds its plan from `ScoreNavigation(score:)`
    /// instead, which reads the score's map; a caller that has a `Score` must never use this entry point.
    static func playbackPlan(for measures: [Measure], division: Int) -> [PlaybackEntry] {
        RepeatUnwinder.plan(
            navigation: ScoreNavigation(staffMeasures: measures, division: division),
        )
    }

    /// Reference duration of a measure in ticks. Uses voice 0; falls back to 4/4
    /// if the measure has no time-bearing elements at all.
    ///
    /// `measureDuration` is the effective duration of this measure (from
    /// `effectiveMeasureDurations`); it is forwarded to
    /// `NoteDuration.resolved(in:)` so that any `.measure` rest is converted
    /// to the correct concrete fraction before the tick count is taken.
    /// Callers that may see non-4/4 measures must pass the effective
    /// duration; the 4/4 default is only safe when the measure contains no
    /// `.measure` rests. `measureIndex` and `tempoMap` place a breath's pause at the tempo where it
    /// stands; both are required so no caller can fall back to 120 BPM by omission.
    static func measureTicks(
        measure: Measure,
        division: Int,
        measureDuration: Fraction = Fraction(numerator: 4, denominator: 4),
        measureIndex: Int,
        tempoMap: ResolvedTempoMap,
    ) -> Int {
        guard let voice = measure.voices.first else { return 4 * division }
        var ticks = 0
        // Where a breath stands before the pauses earlier in the bar — the position the tempo map is read at.
        var nominal = 0
        for element in voice.elements {
            switch element {
            case let .chord(chord):
                let length = chord.duration.resolved(in: measureDuration).ticks(division: division)
                ticks += length
                nominal += length
            case let .measureRepeat(rep):
                let length = rep.duration.resolved(in: measureDuration).ticks(division: division)
                ticks += length
                nominal += length
            case let .breath(b) where b.pause > 0:
                // Breath pauses shift subsequent onsets forward, so the pause counts toward the bar's tick budget and
                // the next bar's playback-plan offset accounts for it — at the tempo the map has where the breath
                // stands, exactly as the voice walk converts it.
                ticks += breathPauseTicks(
                    b.pause,
                    beatsPerSecond: tempoMap.beatsPerSecond(atMeasure: measureIndex, tickInMeasure: nominal),
                    division: division,
                )
            default: continue
            }
        }
        return ticks
    }

    /// The ticks a breath's `pause` (seconds) occupies at `beatsPerSecond`: the onsets after it shift by this much at a
    /// constant tempo, as MuseScore's export does. Every walker — the voice walk, `measureTicks`, both cursor-timeline
    /// walks — converts here, at the tempo map's value where the breath stands (import-fidelity F2.9).
    package static func breathPauseTicks(_ pause: Double, beatsPerSecond: Double, division: Int) -> Int {
        Int((pause * beatsPerSecond * Double(division)).rounded())
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
        voiceIndex: Int,
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
        voiceIndex: Int,
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
            let survivors = candidate.elements.indices.filter {
                switch candidate.elements[$0] {
                case .chord, .dynamic: true
                default: false
                }
            }
            let pairs = survivors.map { (candidate.elements.eid(at: $0), candidate.elements[$0]) }
            return Voice(elements: IdentifiedArray(pairs))
        }
        return Voice(elements: [])
    }
}
