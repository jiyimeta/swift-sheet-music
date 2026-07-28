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
    /// constant offset of roughly one notehead width.
    static let tupletRunCentreTolSpatia: CGFloat = 2

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
            // The mark's xRange is anchored near the STEMS (bracket arms /
            // beam quad), but `RhythmElement.x` is the notehead's ORIGIN —
            // for the common stem-up case that sits roughly a notehead
            // width to the LEFT of its own stem. So a genuine member's x
            // can land just outside the mark's lower bound even though its
            // stem is inside; widen only the lower bound to admit it. The
            // upper bound is left exact: the rightmost member's origin is,
            // if anything, further inside the mark than its own stem, so
            // widening there would only risk pulling in the NEXT (non-
            // member) note — exactly the five-vs-three-sixteenths case this
            // whole pass exists to resolve.
            let lowerBound = mark.xRange.lowerBound - tupletRunCentreTolSpatia * spatium
            let window = out.indices
                .filter {
                    let x = out[$0].x
                    return x >= lowerBound && x <= mark.xRange.upperBound
                        && !claimed.contains($0)
                }
                .sorted { out[$0].x < out[$1].x }
            guard window.count >= 2 else { continue }
            let run = mark.anchor == .bracket
                ? (cleanScale(window, in: out, mark: mark) == nil ? nil : window)
                : bestRun(window, in: out, mark: mark, spatium: spatium)
            guard let run, let scale = cleanScale(run, in: out, mark: mark)
            else { continue }
            for idx in run {
                let f = out[idx].chord.duration.asFraction
                out[idx].chord.duration = .fraction(Fraction(
                    numerator: f.numerator * scale.normal,
                    denominator: f.denominator * scale.actual,
                ))
                out[idx].inTuplet = true
                out[idx].lowConfidenceDuration = false
                claimed.insert(idx)
            }
        }
        return out
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
            switch elements[idx].chord.duration {
            case .measure: return nil
            case let .fraction(f):
                // Already a tuplet value (or dotted). Dotted members are
                // legal; an existing tuplet value means we would scale
                // twice, so refuse.
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
