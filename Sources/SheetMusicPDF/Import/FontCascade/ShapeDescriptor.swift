#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Scale- and translation-invariant description of a glyph outline, used by
/// Tier 4 nearest-neighbor classification.
struct ShapeDescriptor: Hashable {
    var bitmap: GlyphBitmap
    /// Bounding-box width / height BEFORE normalization. Normalization
    /// discards absolute size but this preserves proportion, which separates
    /// a wide notehead from a tall flag.
    var aspectRatio: Double
    /// Fraction of inked cells. Separates a filled notehead from a hollow one.
    var inkDensity: Double
    /// Peaks in the vertical projection profile — the repeated-stroke count
    /// that separates rest8th/16th/32nd/64th and the flag family.
    var flagPeaks: Int

    /// Weighted distance in [0, 1] — the weights sum to 1. Bitmap L1
    /// dominates; the scalar features break ties within a shape family.
    /// `flagPeaks` disagreement carries the largest single scalar weight
    /// because it is the only reliable within-family signal.
    ///
    /// Starting weights — not yet tuned against a real ablation measurement
    /// (that is Task 14's job). Kept as named constants below so that tuning
    /// pass can adjust them without touching the formula.
    func distance(to other: ShapeDescriptor) -> Double {
        let n = bitmap.coverage.count
        guard n > 0, other.bitmap.coverage.count == n else { return .infinity }
        var sum = 0.0
        for i in 0 ..< n {
            sum += abs(Double(bitmap.coverage[i]) - Double(other.bitmap.coverage[i]))
        }
        let bitmapTerm = sum / (Double(n) * 255.0)
        let aspectTerm = abs(aspectRatio - other.aspectRatio)
            / max(aspectRatio, other.aspectRatio, 0.001)
        let densityTerm = abs(inkDensity - other.inkDensity)
        let peakTerm = flagPeaks == other.flagPeaks ? 0.0 : 1.0
        return bitmapTerm * Self.bitmapWeight + aspectTerm * Self.aspectWeight
            + densityTerm * Self.densityWeight + peakTerm * Self.peakWeight
    }

    // Weights sum to 1.0 so the result stays comparable across rounds.
    // Starting values from the design brief; Task 14 tunes these against a
    // real ablation measurement.
    private static let bitmapWeight = 0.55
    private static let aspectWeight = 0.15
    private static let densityWeight = 0.10
    private static let peakWeight = 0.20
}

/// Build a descriptor from a glyph outline.
func makeDescriptor(path: CGPath) -> ShapeDescriptor {
    let box = path.boundingBoxOfPath
    let bitmap = normalizedBitmap(path: path)
    let inked = bitmap.coverage.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
    let aspect = box.height > 0 ? Double(box.width / box.height) : 1
    return ShapeDescriptor(
        bitmap: bitmap,
        aspectRatio: aspect,
        inkDensity: Double(inked) / Double(max(bitmap.coverage.count, 1)),
        flagPeaks: verticalProjectionPeaks(bitmap),
    )
}

/// Count runs of rows whose inked-cell total exceeds a fraction of the row
/// maximum — i.e. the number of distinct horizontal strokes stacked vertically.
func verticalProjectionPeaks(_ bitmap: GlyphBitmap) -> Int {
    let size = GlyphBitmap.size
    var rowSums = [Int](repeating: 0, count: size)
    for r in 0 ..< size {
        var s = 0
        for c in 0 ..< size where bitmap.coverage[r * size + c] > 127 {
            s += 1
        }
        rowSums[r] = s
    }
    guard let peak = rowSums.max(), peak > 0 else { return 0 }
    let threshold = max(1, peak / 2)
    var runs = 0
    var inRun = false
    for s in rowSums {
        if s >= threshold, !inRun { runs += 1; inRun = true } else if s < threshold { inRun = false }
    }
    return runs
}
