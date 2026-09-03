#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// The grouping rule lives in Core as `BeamGrouping` since the edit-command parity project (row 61): the
    /// editor must find a beam group's leading chord by the layout's own rule. These forward so call sites and
    /// `BeamingTests` read as before.
    typealias BeamGroup = SheetMusicCore.BeamGroup

    static func beamGroups(
        voice: Voice,
        timeSignature: TimeSignature?,
        measureDuration: Fraction = Fraction(numerator: 4, denominator: 4),
        division: Int,
    ) -> [BeamGroup] {
        BeamGrouping.groups(
            voice: voice, timeSignature: timeSignature, measureDuration: measureDuration, division: division,
        )
    }

    static func beamLevel(_ dur: NoteDuration) -> Int {
        BeamGrouping.level(of: dur)
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
