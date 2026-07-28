#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// X-ONSET GEOMETRY FIT — the primary discriminator the metric-sum
// reconciliation pass uses to choose WHICH note to re-value. Split out of
// PDFImporter+RhythmReconcile to keep each file under the length cap, the
// same way the tuplet fallback was split into
// PDFImporter+RhythmReconcileTuplet.

extension PDFImporter {
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
    static func onsetFitResidual(
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
