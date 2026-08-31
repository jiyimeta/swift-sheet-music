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
    /// `.measure` rests.
    static func measureTicks(
        measure: Measure,
        division: Int,
        measureDuration: Fraction = Fraction(numerator: 4, denominator: 4),
    ) -> Int {
        guard let voice = measure.voices.first else { return 4 * division }
        var ticks = 0
        for element in voice.elements {
            switch element {
            case let .chord(chord):
                ticks += chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            case let .measureRepeat(rep): ticks += rep.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
            case let .breath(b) where b.pause > 0:
                // Breath pauses shift subsequent note onsets forward
                // at the constant tempo (mirroring MuseScore's
                // ExportMidi behavior). The pause therefore counts
                // toward the measure's total tick budget so the next
                // measure's playback-plan offset accounts for it.
                //
                // TODO: multi-tempo scores — sample the tempo timeline
                // at the breath's tick instead of hard-coding 2.0 bps
                // (120 BPM). Same TODO lives in the layout side.
                let bps = 2.0
                ticks += Int(
                    (b.pause * bps * Double(division)).rounded(),
                )
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
