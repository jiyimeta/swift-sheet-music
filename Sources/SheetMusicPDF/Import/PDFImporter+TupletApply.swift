#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// TUPLET APPLICATION. Given the marks `detectTupletMarks` found, scale the
// members inside each mark's span by `normal/actual`.
//
// This runs BEFORE `reconcileMeasureDurations` on purpose. Scaling a
// tuplet leaves the voice short or long by exactly the collateral error a
// neighbouring note carries (a tuplet read straight is routinely
// compensated by an adjacent note read one value off), and the existing
// single-note metric repair is already good at closing that. Detection
// first, arithmetic second.

extension PDFImporter {
    /// How far (in spatia) a candidate run's x-midpoint may sit from the
    /// digit's centre. Generous because MuseScore centres the number over
    /// the STEMS while `RhythmElement.x` is the notehead's origin, a
    /// constant offset of roughly one notehead width. Used ONLY for the
    /// `.beam` distance tie-break — see `tupletWindowSlackSpatia` for the
    /// (separate) window-membership tolerance.
    static let tupletRunCentreTolSpatia: CGFloat = 2

    /// How far (in spatia) a member's notehead origin may sit outside a
    /// mark's span and still count as inside it. A bracket arm or beam
    /// quad is anchored to the STEM, but `RhythmElement.x` is the
    /// notehead ORIGIN — SMuFL `noteheadBlack` is ~1.18 sp wide, so for
    /// the common stem-up case (stem to the notehead's right) the origin
    /// sits roughly one notehead width left of its own stem. Applied
    /// direction-aware per element in `windowIndices`, never uniformly:
    /// too generous a reach here can swallow a whole unrelated neighbour
    /// (MuseScore's tightest successive-notehead distance is ~1.43 sp).
    static let tupletWindowSlackSpatia: CGFloat = 1.25

    /// Apply every mark, scaling its members' durations and flagging them
    /// `inTuplet`. Marks whose member run fails the clean-sum gate are
    /// dropped and their notes left at their straight values.
    static func applyTupletMarks(
        elements: [RhythmElement],
        marks: [TupletMark],
        spatium: CGFloat,
    ) -> [RhythmElement] {
        guard !marks.isEmpty, !elements.isEmpty else { return elements }
        var out = elements
        var claimed = Set<Int>()
        for mark in marks {
            let widened = windowIndices(
                mark: mark, in: out, claimed: claimed, widen: true, spatium: spatium,
            )
            guard widened.count >= 2 else { continue }
            if mark.anchor == .bracket {
                applyBracket(mark, widened: widened, elements: &out, claimed: &claimed, spatium: spatium)
            } else if let run = bestRun(widened, in: out, mark: mark, spatium: spatium),
                      let scale = cleanScale(run, in: out, mark: mark)
            {
                apply(run, scale: scale, to: &out, claimed: &claimed)
            }
        }
        return out
    }

    /// A `.bracket` mark's span is authoritative, so the widened window is
    /// tried first; if slack swept in a neighbour that breaks the
    /// clean-sum gate, retry once with the STRICT (unwidened) window
    /// before giving up on the whole mark. Losing an authoritative bracket
    /// entirely to a slack heuristic is worse than falling back to exact
    /// containment.
    private static func applyBracket(
        _ mark: TupletMark, widened: [Int],
        elements: inout [RhythmElement], claimed: inout Set<Int>, spatium: CGFloat,
    ) {
        if let scale = cleanScale(widened, in: elements, mark: mark) {
            apply(widened, scale: scale, to: &elements, claimed: &claimed)
            return
        }
        let strict = windowIndices(
            mark: mark, in: elements, claimed: claimed, widen: false, spatium: spatium,
        )
        guard strict.count >= 2, let scale = cleanScale(strict, in: elements, mark: mark)
        else { return }
        apply(strict, scale: scale, to: &elements, claimed: &claimed)
    }

    /// Indices of unclaimed elements inside `mark`'s span, in x-order.
    /// `widen` toggles the notehead-origin-vs-stem slack
    /// (`tupletWindowSlackSpatia`), applied per element and direction-
    /// aware rather than uniformly:
    ///   * A REST has no stem to anchor to, so it gets the slack on BOTH
    ///     sides.
    ///   * A stem-UP (or direction-unknown) note's origin sits left of its
    ///     own stem, so it gets the slack on the LOWER bound only.
    ///   * A stem-DOWN note's origin already sits at its own stem, so no
    ///     slack is justified in either direction — it must satisfy the
    ///     mark's exact span.
    /// The upper bound is never widened for a note: the rightmost true
    /// member's stem sits at or inside the mark's right edge already, so
    /// widening there only risks admitting the NEXT (non-member) note.
    private static func windowIndices(
        mark: TupletMark, in elements: [RhythmElement], claimed: Set<Int>,
        widen: Bool, spatium: CGFloat,
    ) -> [Int] {
        let slack = widen ? tupletWindowSlackSpatia * spatium : 0
        return elements.indices
            .filter { idx in
                guard !claimed.contains(idx) else { return false }
                let element = elements[idx]
                let lower: CGFloat
                let upper: CGFloat
                if element.isRest {
                    lower = mark.xRange.lowerBound - slack
                    upper = mark.xRange.upperBound + slack
                } else if element.stemDirection == .down {
                    lower = mark.xRange.lowerBound
                    upper = mark.xRange.upperBound
                } else {
                    lower = mark.xRange.lowerBound - slack
                    upper = mark.xRange.upperBound
                }
                return element.x >= lower && element.x <= upper
            }
            .sorted { elements[$0].x < elements[$1].x }
    }

    /// Scale every element in `run` by `scale` and flag it `inTuplet`.
    private static func apply(
        _ run: [Int], scale: (normal: Int, actual: Int),
        to elements: inout [RhythmElement], claimed: inout Set<Int>,
    ) {
        for idx in run {
            let f = elements[idx].chord.duration.asFraction
            elements[idx].chord.duration = .fraction(Fraction(
                numerator: f.numerator * scale.normal,
                denominator: f.denominator * scale.actual,
            ))
            elements[idx].inTuplet = true
            elements[idx].lowConfidenceDuration = false
            claimed.insert(idx)
        }
    }

    /// The mark's ratio, if scaling `run` by it lands on a clean written
    /// value; nil otherwise. A real tuplet always fills a plain (possibly
    /// dotted) note value: three sixteenths ⇒ 3/16 × 2/3 = 1/8, a triplet
    /// quarter + eighth ⇒ 3/8 × 2/3 = 1/4. Two straight eighths ⇒ 1/4 × 2/3
    /// = 1/6, which nothing spells, so the run is not a tuplet.
    private static func cleanScale(
        _ run: [Int], in elements: [RhythmElement], mark: TupletMark,
    ) -> (normal: Int, actual: Int)? {
        var sum = Fraction(numerator: 0, denominator: 1)
        for idx in run {
            // Already scaled by an earlier mark in this same pass (or by
            // an upstream stage): never double-scale. This is the exact
            // signal — unlike a denominator%3 check, it still catches a
            // DOTTED member whose scaled result degenerates to a
            // power-of-two-looking `.fraction` (e.g. a dotted quarter's
            // 3/8 scales to 1/4, whose denominator no longer betrays that
            // it was already scaled).
            guard !elements[idx].inTuplet else { return nil }
            switch elements[idx].chord.duration {
            case .measure: return nil
            case let .fraction(f):
                // An existing raw tuplet-shaped fraction not caught by the
                // `inTuplet` flag above (e.g. produced by some other
                // decode path): refuse rather than scale twice. Dotted
                // members are otherwise legal and fall through to `sum +=`.
                guard f.denominator % 3 != 0 else { return nil }
                sum += f
            default:
                sum += elements[idx].chord.duration.asFraction
            }
        }
        let scaled = Fraction(
            numerator: sum.numerator * mark.normal,
            denominator: sum.denominator * mark.actual,
        )
        guard candidateDuration(matching: scaled) != nil else { return nil }
        return (mark.normal, mark.actual)
    }

    /// The contiguous sub-run of `window` that scales cleanly and whose
    /// x-midpoint sits nearest the digit's centre.
    private static func bestRun(
        _ window: [Int], in elements: [RhythmElement],
        mark: TupletMark, spatium: CGFloat,
    ) -> [Int]? {
        var best: (run: [Int], distance: CGFloat)?
        for start in window.indices {
            for end in (start + 1) ..< window.count {
                let run = Array(window[start ... end])
                guard cleanScale(run, in: elements, mark: mark) != nil
                else { continue }
                let lo = elements[run[0]].x
                let hi = elements[run[run.count - 1]].x
                let distance = abs((lo + hi) / 2 - mark.digitCenterX)
                guard distance <= tupletRunCentreTolSpatia * spatium
                else { continue }
                if let current = best {
                    if distance < current.distance { best = (run, distance) }
                } else {
                    best = (run, distance)
                }
            }
        }
        return best?.run
    }
}
