// swiftlint:disable file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    struct BeamGroup: Equatable {
        /// Voice-element indices (into `voice.elements`) of the chords in
        /// this beam group. Always length >= 2.
        let memberIndices: [Int]
        /// 1 = eighth-style (one beam bar), 2 = 16th (two bars), etc.
        let level: Int
    }

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
    static func beamGroups( // swiftlint:disable:this function_body_length
        voice: Voice,
        timeSignature: TimeSignature?,
        division: Int,
    ) -> [BeamGroup] {
        let beatLen = oneBeatTicks(
            timeSignature: timeSignature, division: division,
        )
        let maxGroupLen = beamGroupTicks(
            timeSignature: timeSignature, division: division,
        )

        // Pre-scan: for each beat, collect the DISTINCT beam levels so
        // we can tell whether the beat is "uniform" (all notes share a
        // single level) or "mixed" (multiple levels coexist). MuseScore
        // merges beats only when BOTH sides of the boundary are uniform
        // — a beat containing a dotted-8th + 16th has levels {1, 2}
        // (mixed) and forces a break even though both levels appear in
        // the neighbouring beat too.
        var beatLevelSets: [Int: Set<Int>] = [:]
        var scanTick = 0
        for el in voice.elements {
            switch el {
            case let .chord(c):
                let level = beamLevel(c.duration)
                if level > 0 && beatLen > 0 {
                    let beat = scanTick / beatLen
                    beatLevelSets[beat, default: Set()].insert(level)
                }
                scanTick += c.duration.ticks(division: division)
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
                tick += c.duration.ticks(division: division)
            case let .chord(c):
                let level = beamLevel(c.duration)
                if level == 0 {
                    flush()
                    tick += c.duration.ticks(division: division)
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
                tick += c.duration.ticks(division: division)
            default:
                if case .barLine = el { flush() }
            }
        }
        flush()
        return groups
    }

    /// One beat in ticks — the INNER boundary for the subdivision
    /// check. Different from `beamGroupTicks` which is the OUTER
    /// (max) boundary.
    private static func oneBeatTicks(
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

    static func beamLevel(_ dur: NoteDuration) -> Int {
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
    static func beamGroupTicks(
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

    // MARK: - Beam slope

    /// Endpoint y-coordinates of a sloped beam line.
    struct BeamLine: Equatable {
        let startY: CGFloat
        let endY: CGFloat
    }

    /// Compute the beam line (start y + end y) for a group, following a
    /// simplified version of MuseScore's beamtremololayout algorithm:
    ///
    /// 1. Desired slant = interval between first and last anchor steps.
    /// 2. FLAT constraint: if any middle chord's anchor is strictly
    ///    more extreme than both endpoints (higher for stem-up, lower
    ///    for stem-down), the beam is flat.
    /// 3. Max slant is capped by the smaller of:
    ///    - interval-based cap (larger intervals allow steeper slope)
    ///    - beam-width-based cap (short beams can't have steep slopes)
    ///    Both expressed in staff steps (half a sp per step).
    /// 4. The beam is placed so the MORE EXTREME endpoint has exactly
    ///    `defaultStemLength` stem reach; the other endpoint is offset
    ///    by the signed slant.
    ///
    /// `anchorYs[i]` is the y of each chord's beam-side notehead (the
    /// highest for stem-up, the lowest for stem-down). `anchorSteps[i]`
    /// is the corresponding staff step. `stemXs[i]` is the stem x for
    /// that chord.
    static func computeBeamLine( // swiftlint:disable:this function_body_length
        anchorSteps: [Int],
        anchorYs: [CGFloat],
        stemXs: [CGFloat],
        direction: StemDirection,
        metrics: StaffMetrics,
    ) -> BeamLine {
        precondition(anchorSteps.count == anchorYs.count)
        precondition(anchorSteps.count == stemXs.count)
        let stemLen = metrics.defaultStemLength

        guard anchorSteps.count >= 2,
              let startStep = anchorSteps.first,
              let endStep = anchorSteps.last,
              let startAnchorY = anchorYs.first,
              let endAnchorY = anchorYs.last,
              let firstStemX = stemXs.first,
              let lastStemX = stemXs.last
        else {
            let y = (anchorYs.first ?? 0)
                + (direction == .up ? -stemLen : stemLen)
            return BeamLine(startY: y, endY: y)
        }

        // Flat beam at the most extreme anchor — default fallback.
        let extremeY: CGFloat = direction == .up
            ? (anchorYs.min() ?? 0)
            : (anchorYs.max() ?? 0)
        let flatY = direction == .up
            ? extremeY - stemLen
            : extremeY + stemLen

        // FLAT constraint: a middle anchor is more extreme than both
        // endpoints. Strict inequality — equal heights use slope.
        if anchorSteps.count > 2 {
            let middles = anchorSteps.dropFirst().dropLast()
            let endsExtreme = direction == .up
                ? max(startStep, endStep)
                : min(startStep, endStep)
            for mid in middles {
                if direction == .up, mid > endsExtreme {
                    return BeamLine(startY: flatY, endY: flatY)
                }
                if direction == .down, mid < endsExtreme {
                    return BeamLine(startY: flatY, endY: flatY)
                }
            }
        }

        let intervalSteps = abs(endStep - startStep)
        if intervalSteps == 0 {
            return BeamLine(startY: flatY, endY: flatY)
        }

        // Max slant in STEPS (= half sp). MuseScore's _maxSlopes table
        // is in quarter-sp; I round to steps for simpler arithmetic.
        // Shape still matches: small intervals and short beams get
        // modest slopes, larger ones get more.
        let maxByInterval = min(intervalSteps, 4)

        let beamWidthSp = max(
            0.01,
            (lastStemX - firstStemX) / metrics.sp,
        )
        let maxByWidth: Int
        switch beamWidthSp {
        case ..<3: maxByWidth = 1
        case ..<5: maxByWidth = 2
        case ..<7.5: maxByWidth = 3
        case ..<10: maxByWidth = 4
        case ..<12.5: maxByWidth = 5
        default: maxByWidth = 6
        }

        let slantSteps = min(intervalSteps, min(maxByInterval, maxByWidth))
        // endStep > startStep ⇒ beam rises visually ⇒ endY < startY.
        let slantSign: CGFloat = endStep > startStep ? -1 : 1
        let slantY = CGFloat(slantSteps) * metrics.sp * 0.5 * slantSign

        // Place the beam so the ENDPOINT that is already most extreme
        // gets exactly `stemLen` of stem; the other endpoint is offset
        // by the signed slant.
        let startY: CGFloat
        let endY: CGFloat
        switch direction {
        case .up:
            // Higher anchor = smaller y.
            if startAnchorY <= endAnchorY {
                startY = startAnchorY - stemLen
                endY = startY + slantY
            } else {
                endY = endAnchorY - stemLen
                startY = endY - slantY
            }
        case .down:
            if startAnchorY >= endAnchorY {
                startY = startAnchorY + stemLen
                endY = startY + slantY
            } else {
                endY = endAnchorY + stemLen
                startY = endY - slantY
            }
        }
        return BeamLine(startY: startY, endY: endY)
    }
}
