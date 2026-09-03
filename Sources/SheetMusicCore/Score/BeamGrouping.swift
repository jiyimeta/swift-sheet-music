import SheetMusicFoundation

/// One beam group: the voice-element indices of its chords (always >= 2) and its beam level
/// (1 = eighth, 2 = sixteenth, …). Moved from `LayoutEngine.BeamGroup` for the edit-command parity project
/// (spec 2026-09-02 row 61): the flag that hides a beam lives on the group's LEADING chord, so the editor has to
/// find that chord by the very rule the layout groups with, or the two disagree on the first 6/8 bar.
package struct BeamGroup: Equatable {
    /// Voice-element indices (into `voice.elements`) of the chords in
    /// this beam group. Always length >= 2.
    package let memberIndices: [Int]
    /// 1 = eighth-style (one beam bar), 2 = 16th (two bars), etc.
    package let level: Int

    package init(memberIndices: [Int], level: Int) {
        self.memberIndices = memberIndices
        self.level = level
    }
}

/// The beam-grouping rule — a simplified `Groups::actualBeamMode` + `beatSubdivision` — and the two lookups the
/// editor needs on top of it. `SheetMusicLayout` forwards to these (`LayoutEngine.beamGroups`, `beamLevel`) rather
/// than keeping a copy, so "the group's leading chord" means the same thing on both sides.
package enum BeamGrouping {
    /// Compute beam groups for a single voice under the given time
    /// signature. Implements a simplified version of MuseScore's
    /// `Groups::actualBeamMode` + `beatSubdivision` logic:
    ///
    /// 1. Always break at the **max beam-group boundary** (half note
    ///    in 4/4, dotted quarter in 6/8, etc.).
    /// 2. At **beat boundaries** within that span, break ONLY when
    ///    the minimum beam level in the just-ended beat differs from
    ///    the minimum level in the upcoming beat. This lets 4 uniform
    ///    8ths (both beats have min=1) merge into one group, while
    ///    "dotted-8th + 16th | 8th + 8th" (beat-1 min=2, beat-2
    ///    min=1) still splits at the beat.
    package static func groups( // swiftlint:disable:this function_body_length
        voice: Voice,
        timeSignature: TimeSignature?,
        measureDuration: Fraction = Fraction(numerator: 4, denominator: 4),
        division: Int,
    ) -> [BeamGroup] {
        let beatLen = beatTicks(
            timeSignature: timeSignature, division: division,
        )
        let maxGroupLen = groupTicks(
            timeSignature: timeSignature, division: division,
        )

        // Pre-scan: for each beat, collect the DISTINCT beam levels so
        // we can tell whether the beat is "uniform" (all notes share a
        // single level) or "mixed" (multiple levels coexist). MuseScore
        // merges beats only when BOTH sides of the boundary are uniform
        // — a beat containing a dotted-8th + 16th has levels {1, 2}
        // (mixed) and forces a break even though both levels appear in
        // the neighboring beat too.
        var beatLevelSets: [Int: Set<Int>] = [:]
        var scanTick = 0
        for el in voice.elements {
            switch el {
            case let .chord(c):
                let level = Self.level(of: c.duration)
                if level > 0 && beatLen > 0 {
                    let beat = scanTick / beatLen
                    beatLevelSets[beat, default: Set()].insert(level)
                }
                scanTick += c.duration.resolved(in: measureDuration).ticks(division: division)
            case let .locationShift(delta):
                // Same cursor rule as `placeMeasureElements` — a voice
                // starting part-way through the measure must land on
                // the real beats, or every beat-boundary decision
                // below is taken against the wrong beat index.
                scanTick += delta.ticks(division: division)
            // Empty chord = rest, picked up by the .chord case above
            // since c.notes.isEmpty contributes 0 elements to beam
            // groups but still advances scanTick.
            default:
                break
            }
        }

        // Main pass — build groups with the two-level boundary check.
        var tick = 0
        var groups: [BeamGroup] = []
        var currentIndices: [Int] = []
        var currentLevel = 0
        func flush() {
            if currentIndices.count >= 2 && currentLevel >= 1 {
                groups.append(BeamGroup(
                    memberIndices: currentIndices, level: currentLevel,
                ))
            }
            currentIndices.removeAll()
            currentLevel = 0
        }
        for (i, el) in voice.elements.enumerated() {
            switch el {
            case let .chord(c) where c.notes.isEmpty:
                // Rest: breaks any in-progress beam group.
                flush()
                tick += c.duration.resolved(in: measureDuration).ticks(division: division)
            case let .chord(c):
                let level = Self.level(of: c.duration)
                if level == 0 {
                    flush()
                    tick += c.duration.resolved(in: measureDuration).ticks(division: division)
                    continue
                }
                if tick > 0 {
                    // Hard boundary (half-note in 4/4).
                    if maxGroupLen > 0 && tick % maxGroupLen == 0 {
                        flush()
                    }
                    // Beat boundary rules:
                    //
                    // 1. If EITHER side of the boundary contains a
                    //    **secondary-beam** duration (16th or
                    //    shorter), flush.  MuseScore's engraver
                    //    ("Groups::actualBeamMode") breaks secondary
                    //    beams at every beat, so e.g. two beats of
                    //    straight 16ths appear as 4+4 rather than a
                    //    single run of 8 — even though both beats are
                    //    "uniform" at level 2.
                    //
                    // 2. Otherwise (both sides primary-only or empty),
                    //    merge only when BOTH beats are uniform at
                    //    level 1.  Mixed level-1/2 beats (dotted-8th +
                    //    16th) are handled by rule 1 above; a non-
                    //    uniform level-1-only beat (rare, e.g. ties
                    //    producing different effective durations) still
                    //    forces a break.
                    else if beatLen > 0 && tick % beatLen == 0 {
                        let curBeat = tick / beatLen
                        let prevBeat = curBeat - 1
                        let prevMax = beatLevelSets[prevBeat]?.max() ?? 0
                        let curMax = beatLevelSets[curBeat]?.max() ?? 0
                        let secondaryInvolved =
                            prevMax >= 2 || curMax >= 2
                        if secondaryInvolved {
                            flush()
                        } else {
                            let prevUniform =
                                (beatLevelSets[prevBeat]?.count ?? 0) <= 1
                            let curUniform =
                                (beatLevelSets[curBeat]?.count ?? 0) <= 1
                            if !(prevUniform && curUniform) { flush() }
                        }
                    }
                }
                currentIndices.append(i)
                currentLevel = max(currentLevel, level)
                tick += c.duration.resolved(in: measureDuration).ticks(division: division)
            case let .locationShift(delta):
                tick += delta.ticks(division: division)
            default:
                if case .barLine = el { flush() }
            }
        }
        flush()
        return groups
    }

    package static func level(of dur: NoteDuration) -> Int {
        // Unwrap a dotted duration (stored as `.fraction`) to its base
        // — a dotted 8th beams like an 8th (level 1), not like a
        // non-beamable fraction.
        let (base, _) = DurationInterpretation.split(dur)
        switch base {
        case .eighth: return 1
        case .sixteenth: return 2
        case .thirtySecond: return 3
        case .sixtyFourth: return 4
        case .oneTwentyEighth: return 5
        case .twoFiftySixth: return 6
        default: return 0
        }
    }

    /// The tick span within which beamable notes stay connected (the
    /// "beam group" boundary). MuseScore's `Groups` class encodes
    /// per-duration break points; we simplify to common practice:
    ///
    /// - **Compound meters** (6/8, 9/8, 12/8): dotted quarter
    ///   (3 8ths per group).
    /// - **4/4, 2/4, 2/2**: half note (4 8ths per group). This
    ///   matches modern American engraving where the half-bar is
    ///   the natural beam break, not the individual beat.
    /// - **Other meters** (3/4, 5/4, 7/8, etc.): single beat.
    package static func groupTicks(
        timeSignature: TimeSignature?, division: Int,
    ) -> Int {
        guard let ts = timeSignature else { return division * 2 }

        // Compound meter: group = dotted quarter.
        if ts.denominator == 8
            && ts.numerator % 3 == 0
            && ts.numerator > 0
        {
            return (division * 3) / 2
        }

        let oneBeat = (division * 4) / max(1, ts.denominator)

        // Duple / quadruple simple meters with half-note grouping.
        switch (ts.numerator, ts.denominator) {
        case (4, 4), (2, 4), (2, 2), (4, 8):
            return oneBeat * 2
        default:
            return oneBeat
        }
    }

    /// One beat in ticks — the INNER boundary for the subdivision
    /// check. Different from `groupTicks` which is the OUTER
    /// (max) boundary.
    private static func beatTicks(
        timeSignature: TimeSignature?, division: Int,
    ) -> Int {
        guard let ts = timeSignature else { return division }
        if ts.denominator == 8
            && ts.numerator % 3 == 0
            && ts.numerator > 0
        {
            return (division * 3) / 2
        }
        return (division * 4) / max(1, ts.denominator)
    }

    /// The `TimeSignature` element the layout hands `groups(…)` for a measure: the first `.timeSignature` in
    /// any voice of THAT measure, `nil` when the bar declares none (`LayoutEngine+Placement.swift`, moved here
    /// so the editor asks the same question). Deliberately not the meter in force — the layout never carried
    /// the prevailing meter into this call, and matching the layout is the whole point.
    package static func explicitTimeSignature(in measure: Measure) -> TimeSignature? {
        for voice in measure.voices {
            for element in voice.elements {
                if case let .timeSignature(ts) = element { return ts }
            }
        }
        return nil
    }

    /// The leading chord of the beam group containing `location`, or `nil` when the element is not a member of
    /// any group — a rest, a quarter, a lone eighth, or a slot that does not exist. Grouped exactly as the layout
    /// groups it: the measure's own time-signature element and the staff's effective bar length
    /// (`Score.effectiveMeasureDuration(at:measureIndex:)`).
    package static func leader(of location: VoiceElementID, in score: Score) -> VoiceElementID? {
        guard let measure = score[measure: MeasureRef(measureIndex: location.measureIndex), staff: location.staff],
              measure.voices.indices.contains(location.voiceIndex)
        else { return nil }
        let groups = groups(
            voice: measure.voices[location.voiceIndex],
            timeSignature: explicitTimeSignature(in: measure),
            measureDuration: score.effectiveMeasureDuration(at: location.staff, measureIndex: location.measureIndex),
            division: score.division,
        )
        guard let group = groups.first(where: { $0.memberIndices.contains(location.elementIndex) }),
              let lead = group.memberIndices.first
        else { return nil }
        return location.withElementIndex(lead)
    }
}
