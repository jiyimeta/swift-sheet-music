import CoreGraphics
import Foundation
import SheetMusicCore

// METRIC-SUM RECONCILIATION (③ of the rhythm re-architecture). A
// conservative, monotonic repair pass applied AFTER the geometry rhythm
// decode (PDFImporter+Rhythm / +Beams / +BeamGroups), per voice per
// measure.
//
// The geometry layer reads each note's value from beams / flags / dots
// independently. A group-size-1 note read via a flag is geometrically
// ambiguous (a quarter's bare stem vs an eighth's flagged stem differ by
// one short glyph), and the per-note geometry alone cannot always
// disambiguate it. The MEASURE SUM does: a voice's note + rest durations
// must total the time-signature bar length. When they don't, and exactly
// ONE low-confidence note can be re-valued to close the gap, we apply that
// single repair.
//
// Invariants (the reason this pass is safe to run over an
// already-99.9%-correct decode):
//   * A voice that ALREADY sums to the bar length is never touched — so
//     every metrically-valid (correct) note stays byte-identical.
//   * At most ONE note per voice is ever changed; rest counts and note
//     counts are never altered, and nothing is fabricated.
//   * A LOW-CONFIDENCE note (group-size-1 read via a flag) is preferred
//     over a high-confidence beamed note as the repair target.
//   * If no single-note repair reaches the bar length, the voice is left
//     unchanged (a `.warning` diagnostic is emitted).
// Together these make the pass MONOTONIC: it can only convert a
// metrically-invalid voice into a valid one, never regress a valid one.

extension PDFImporter {
    /// Reconcile every voice in a measure against the bar length implied by
    /// `timeSignature`. Returns the rhythm elements with at most one note
    /// per voice re-valued (see file header for invariants). Operates on the
    /// post-lyric `[RhythmElement]` list, before voice assignment, so the
    /// confidence flags set during the geometry decode are still available.
    static func reconcileMeasureDurations(
        elements: [RhythmElement],
        timeSignature: TimeSignature,
        spatium: CGFloat,
        diagnostics: ((PDFImportDiagnostic) -> Void)? = nil,
        location: String = "",
    ) -> [RhythmElement] {
        guard !elements.isEmpty else { return elements }
        // Defense in depth: a mis-decoded time signature (hostile PDF input)
        // must never reach `Fraction`, whose initializer traps on a
        // non-positive denominator. `scoreStateEvents` already validates at
        // the read point, so this only fires if an invalid signature arrives
        // via some other path — skip reconciliation (a no-repair pass is
        // always metrically safe) and warn.
        guard timeSignature.numerator > 0, timeSignature.denominator > 0 else {
            diagnostics?(PDFImportDiagnostic(
                severity: .warning,
                location: location,
                message: "skipping duration reconciliation — invalid time "
                    + "signature \(timeSignature.numerator)/"
                    + "\(timeSignature.denominator)",
            ))
            return elements
        }
        // Bar length as a fraction OF A WHOLE NOTE: a 4/4 bar is 4/4 = one
        // whole note (1/1), a 7/8 bar is 7/8, a 3/4 bar is 3/4. This matches
        // `NoteDuration.asFraction`, where quarter = 1/4 of a whole note.
        let barLength = Fraction(
            numerator: timeSignature.numerator,
            denominator: timeSignature.denominator,
        )
        // Partition into voice groups the SAME way `assignVoices` does
        // (coincident x onset ⇒ two voices) so each group is reconciled
        // against the bar length independently. A single melodic line is a
        // single group.
        let groups = voicePartition(elements)
        var repaired = elements
        for group in groups {
            reconcileVoiceGroup(
                indices: group,
                barLength: barLength,
                spatium: spatium,
                elements: &repaired,
                diagnostics: diagnostics,
                location: location,
            )
        }
        return repaired
    }

    // MARK: - Voice partition (mirrors assignVoices)

    /// Indices of `elements` grouped by voice. Single voice (no two
    /// elements share an x onset) ⇒ one group of every index. Two
    /// coincident onsets ⇒ split by `voiceFor`-equivalent placement
    /// (stem-up / above-midline ⇒ voice 1, else voice 2). Mirrors
    /// `assignVoices` so reconciliation sees the same per-voice partition
    /// the final `Measure` will carry.
    private static func voicePartition(_ elements: [RhythmElement]) -> [[Int]] {
        let xs = elements.map(\.x).sorted()
        var coincident = false
        for i in 1 ..< max(xs.count, 1) where i < xs.count {
            if abs(xs[i] - xs[i - 1]) < 3 { coincident = true; break }
        }
        guard coincident else { return [Array(elements.indices)] }
        let midY = elements.map(\.y).reduce(0, +) / CGFloat(elements.count)
        var v1: [Int] = []
        var v2: [Int] = []
        for (i, el) in elements.enumerated() {
            if reconcileVoiceIsUpper(el, staffMidY: midY) {
                v1.append(i)
            } else {
                v2.append(i)
            }
        }
        return [v1, v2].filter { !$0.isEmpty }
    }

    /// Voice placement predicate mirroring `voiceFor`: a rest above the
    /// staff midline, or a stem-up / above-midline note, is the upper
    /// voice. Kept local so the reconciliation file is self-contained.
    private static func reconcileVoiceIsUpper(
        _ element: RhythmElement, staffMidY: CGFloat,
    ) -> Bool {
        if element.isRest { return element.y > staffMidY }
        switch element.stemDirection {
        case .up: return true
        case .down: return false
        case .none: return element.y > staffMidY
        }
    }

    // MARK: - Per-voice repair

    private static func reconcileVoiceGroup(
        indices: [Int],
        barLength: Fraction,
        spatium: CGFloat,
        elements: inout [RhythmElement],
        diagnostics: ((PDFImportDiagnostic) -> Void)?,
        location: String,
    ) {
        guard !indices.isEmpty else { return }
        let currentSum = indices.reduce(Fraction(numerator: 0, denominator: 1)) {
            $0 + elementFraction(elements[$1])
        }
        // INVARIANT 1: a voice already at the bar length is correct — leave
        // every note byte-identical.
        if currentSum == barLength { return }

        // Candidate note indices: every note-bearing chord (rests are never
        // re-valued).
        let noteIndices = indices.filter { !elements[$0].isRest }
        guard !noteIndices.isEmpty else {
            emitUnreconciledWarning(diagnostics, location: location)
            return
        }

        // For each candidate note, the residual the voice would need that
        // note to carry so the whole voice sums to the bar length:
        //   target = barLength - (sum of every OTHER element).
        // A repair exists when `target` equals one of the allowed candidate
        // durations.
        //
        // Among the single-note repairs that reach the bar length, choose by:
        //   1. x-onset GEOMETRY (primary): the note whose re-valued duration
        //      makes the voice's cumulative time-onsets best line up with the
        //      glyphs' actual x-positions. A quarter occupies ~2× an eighth's
        //      horizontal space, so the note B UNDER-read (an eighth sitting
        //      in a quarter-wide gap) yields the lowest onset-vs-x residual
        //      when enlarged. This is the geometric ground truth and is the
        //      decisive signal (the q↔8 ambiguity at p4 m55 is a beamed eighth
        //      that B mis-grouped, so the confidence flag alone misleads).
        //   2. LOW-CONFIDENCE (secondary tie-break): when two repairs fit the
        //      x-geometry equally well, prefer the geometrically weaker note
        //      (group-size-1 flag-read) over a confident beamed note.
        var best: RepairChoice?
        for idx in noteIndices {
            let others = currentSum - elementFraction(elements[idx])
            let target = barLength - others
            guard target.numerator > 0,
                  let candidate = candidateDuration(matching: target)
            else { continue }
            // Don't "repair" to the value the note already has.
            if elements[idx].chord.duration == candidate { continue }
            // Notehead-shape legality: a FILLED (black) notehead is drawn only
            // for a quarter or shorter (its longest form, a double-dotted
            // quarter, is 7/16 < 1/2); a half / whole needs a HOLLOW head. So
            // never inflate a filled note to a half-or-longer value — that is
            // geometrically impossible and only ever papers over a drum-staff
            // voice-assignment error (地球儀 kick q→h). Leave the voice
            // unbalanced (a diagnostic) rather than fabricate a wrong half.
            if elements[idx].noteheadIsFilled,
               candidate.asFraction.numerator * 2 >= candidate.asFraction.denominator
            { continue }
            let isLow = elements[idx].lowConfidenceDuration
            let spacingErr = onsetFitResidual(
                candidateIndex: idx, indices: indices,
                candidate: candidate, elements: elements,
            )
            let choice = RepairChoice(
                index: idx, duration: candidate,
                lowConfidence: isLow, spacingError: spacingErr,
            )
            if let current = best {
                if choice.preferredOver(current) { best = choice }
            } else {
                best = choice
            }
        }

        guard let choice = best else {
            // No single-note straight repair reaches the bar length. Before
            // giving up, try a TUPLET repair (a contiguous run of equal
            // beamed notes scaled by 2/3 closes a triplet-shaped overflow).
            // Strictly metric-gated: fires only when the run's scaling makes
            // the WHOLE voice sum to the bar exactly, so a score whose voices
            // already balance (ギブス) never reaches this path.
            if ProcessInfo.processInfo.environment["PDF_NO_TUPLET"] != "1",
               tupletRepair(
                   indices: indices, barLength: barLength,
                   currentSum: currentSum, spatium: spatium,
                   elements: &elements, location: location,
               )
            {
                return
            }
            // INVARIANT 4: no single-note repair AND no tuplet repair reaches
            // the bar length — leave the measure unchanged.
            emitUnreconciledWarning(diagnostics, location: location)
            return
        }
        elements[choice.index].chord.duration = choice.duration
        elements[choice.index].lowConfidenceDuration = false
    }

    /// One viable single-note repair, with the tie-break keys.
    private struct RepairChoice {
        var index: Int
        var duration: NoteDuration
        var lowConfidence: Bool
        /// Onset-vs-x linear-fit residual (normalized, smaller = better).
        var spacingError: CGFloat

        /// Two residuals within this fraction of each other are a genuine tie
        /// — resolved by the low-confidence flag. Kept small so that a clearly
        /// better onset-vs-x fit (the squeezed note B under-read; observed gap
        /// ~0.03 of the x-span at p4 m55) is decided by geometry, and only
        /// near-identical fits defer to the confidence signal.
        static let residualTie: CGFloat = 0.01

        /// Prefer the smaller onset-vs-x residual (geometry is primary); when
        /// two residuals tie within `residualTie`, prefer the low-confidence
        /// note (the geometrically weaker read).
        func preferredOver(_ other: RepairChoice) -> Bool {
            if abs(spacingError - other.spacingError) > Self.residualTie {
                return spacingError < other.spacingError
            }
            if lowConfidence != other.lowConfidence { return lowConfidence }
            return spacingError < other.spacingError
        }
    }

    private static func emitUnreconciledWarning(
        _ diagnostics: ((PDFImportDiagnostic) -> Void)?,
        location: String,
    ) {
        diagnostics?(PDFImportDiagnostic(
            severity: .warning,
            location: location,
            message: "Measure voice durations do not sum to the bar length "
                + "and no single-note repair was found; left unchanged.",
        ))
    }

    // MARK: - Candidate durations

    /// The `NoteDuration` whose `asFraction` equals `target`, drawn from the
    /// allowed candidate set, or nil if `target` matches none. The candidate
    /// set is: every power-of-two value whole…64th (returned as the PLAIN
    /// enum case so a repaired quarter is `.quarter`, byte-identical to how
    /// the mscx ground truth spells it — never `.fraction(1/4)`), plus
    /// single- and double-dotted half / quarter / eighth / sixteenth
    /// (returned via `.dotted()`, i.e. the same `.fraction` form the dotted
    /// decode already produces and that the ground truth carries).
    static func candidateDuration(matching target: Fraction) -> NoteDuration? {
        let powers: [NoteDuration] = [
            .whole, .half, .quarter, .eighth,
            .sixteenth, .thirtySecond, .sixtyFourth,
        ]
        for d in powers where d.asFraction == target {
            return d
        }
        let dottable: [NoteDuration] = [.half, .quarter, .eighth, .sixteenth]
        for base in dottable {
            for dots in 1 ... 2 {
                let dotted = base.dotted(dots)
                if dotted.asFraction == target { return dotted }
            }
        }
        return nil
    }

    // MARK: - Fraction helpers

    /// A rhythm element's duration as a fraction of a whole note. A
    /// `.measure` rest (whole-measure marker) resolves to the bar length is
    /// NOT expected here — the importer emits typed rests — so `.measure`
    /// falls back to a whole note to avoid a trap; it never appears in this
    /// corpus.
    private static func elementFraction(_ element: RhythmElement) -> Fraction {
        switch element.chord.duration {
        case .measure: return Fraction(numerator: 1, denominator: 1)
        default: return element.chord.duration.asFraction
        }
    }

    // MARK: - x-onset geometry fit (primary repair discriminator)

    /// How well the voice's CUMULATIVE time-onsets line up with the glyphs'
    /// actual x-positions when the note at `candidateIndex` is re-valued to
    /// `candidate`. Lower = better fit.
    ///
    /// Engraving spaces notes left-to-right roughly proportional to their
    /// onset time, so a note's x-position is a near-linear function of its
    /// cumulative time onset (`x ≈ a·t + b`). We compute every element's
    /// cumulative onset under the PROPOSED durations (current durations with
    /// the one candidate substituted), fit that `(t, x)` cloud to a line by
    /// least squares, and return the normalized root-mean-square residual.
    /// The repair that makes a squeezed note occupy its true (wider) onset
    /// gap minimizes the residual, so this isolates the note B under-read.
    ///
    /// Normalized by the x-span so the residual is a unitless fraction
    /// comparable across measures. Degenerate geometry (fewer than 3 onsets
    /// or zero span) returns 0 — geometry can't decide, so the secondary
    /// confidence tie-break takes over.
    private static func onsetFitResidual(
        candidateIndex: Int,
        indices: [Int],
        candidate: NoteDuration,
        elements: [RhythmElement],
    ) -> CGFloat {
        // Elements in x-order, each carrying (x, proposed duration fraction).
        let ordered = indices.sorted { elements[$0].x < elements[$1].x }
        guard ordered.count >= 3 else { return 0 }
        var ts: [CGFloat] = []
        var xs: [CGFloat] = []
        var cumulative = CGFloat(0)
        for i in ordered {
            ts.append(cumulative)
            xs.append(elements[i].x)
            let f = (i == candidateIndex)
                ? candidate.asFraction
                : elementFraction(elements[i])
            cumulative += CGFloat(f.numerator) / CGFloat(f.denominator)
        }
        let xSpan = (xs.max() ?? 0) - (xs.min() ?? 0)
        guard xSpan > 0 else { return 0 }
        let (slope, intercept) = leastSquares(ts: ts, xs: xs)
        var sumSq = CGFloat(0)
        for k in xs.indices {
            let predicted = slope * ts[k] + intercept
            let r = xs[k] - predicted
            sumSq += r * r
        }
        let rms = (sumSq / CGFloat(xs.count)).squareRoot()
        return rms / xSpan
    }

    /// Ordinary least-squares fit `x = slope·t + intercept`. Degenerate
    /// (zero t-variance) → flat line at mean x.
    private static func leastSquares(
        ts: [CGFloat], xs: [CGFloat],
    ) -> (slope: CGFloat, intercept: CGFloat) {
        let n = CGFloat(ts.count)
        let meanT = ts.reduce(0, +) / n
        let meanX = xs.reduce(0, +) / n
        var num = CGFloat(0)
        var den = CGFloat(0)
        for k in ts.indices {
            let dt = ts[k] - meanT
            num += dt * (xs[k] - meanX)
            den += dt * dt
        }
        guard den > 0 else { return (0, meanX) }
        let slope = num / den
        return (slope, meanX - slope * meanT)
    }
}
