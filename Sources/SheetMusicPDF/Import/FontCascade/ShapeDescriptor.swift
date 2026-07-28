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
    /// Outline height in STAFF SPACES, and the height of its bottom edge above
    /// the baseline in staff spaces.
    ///
    /// SMuFL defines the em square to BE the staff height (four spaces), so a
    /// bbox measured in em units is a staff-relative measurement every
    /// conforming font agrees on. Measured across the corpus's three faces:
    ///
    ///     glyph        Bravura   Leland   MScore
    ///     clefG    h     7.02     7.12     7.14
    ///     clefG8vb h     7.90     8.04     8.29
    ///     clefG    lo   -2.63    -2.67    -2.48
    ///     clefG8vb lo   -3.51    -3.59    -3.63
    ///     restWhole lo  -0.54    -0.52    -0.62
    ///     restHalf  lo  -0.01    -0.02     0.00
    ///
    /// Between-class distance is 0.5-0.9 space; between-font spread within a
    /// class is under 0.15. That is the design-invariant signal the rest of
    /// this descriptor lacks — bbox normalization deliberately discards
    /// absolute size and position, which is exactly what separates a clef
    /// from the same clef with an octave digit, and a whole rest (hanging
    /// below its line) from a half rest (sitting above it).
    var emHeight: Double
    var emBottom: Double

    /// Weighted distance in [0, 1] — the weights sum to 1. Bitmap L1
    /// dominates; the scalar features break ties within a shape family.
    ///
    /// The weights below are the TUNED values, measured (not guessed)
    /// against the Tier-1 ablation over the real corpus. The design brief
    /// expected `flagPeaks` to be the strongest scalar signal; measurement
    /// said the opposite and it now carries the SMALLEST weight of the
    /// three. Its term is binary — peaks either agree or they do not — so
    /// at any appreciable weight it swamped the graded features whenever a
    /// thin flag hook fell under `verticalProjectionPeaks`'s threshold.
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
        // Divided by the em (four spaces) so the term is in [0, 1] for any
        // pair a music font can produce, and clamped so an outlier glyph
        // cannot dominate the whole distance.
        let emTerm = min(
            1.0,
            (abs(emHeight - other.emHeight) + abs(emBottom - other.emBottom)) / 4,
        )
        return bitmapTerm * Self.bitmapWeight + aspectTerm * Self.aspectWeight
            + densityTerm * Self.densityWeight + peakTerm * Self.peakWeight
            + emTerm * Self.emWeight
    }

    // Weights sum to 1.0 so the result stays comparable across rounds.
    // Tuned in single-change rounds, each one required to regress no score in
    // the corpus; same-font-family agreement with Tier 1 rose from 84-91% to
    // 95.6-99.3%, and adding `emWeight` took it to 98.1-99.7% — through the
    // old whole/half-rest ceiling, which that feature removed.
    //
    // `emWeight` was carved out of `bitmapWeight` (0.718 → 0.618) rather than
    // spread across the other three, so the round changed exactly one thing:
    // how much of the verdict the raster silhouette owns. 0.20 was tried
    // first and REJECTED: it pushed MScore's F clef (3.10 spaces tall against
    // Bravura's 3.59 — a real design difference, not noise) past
    // `shapeAcceptanceThreshold`, so 39 bass clefs went unclassified and that
    // score's pitch accuracy stalled at 79%. At 0.10 every corpus score
    // improved or held.
    private static let bitmapWeight = 0.618
    private static let aspectWeight = 0.15
    private static let densityWeight = 0.10
    private static let peakWeight = 0.032
    private static let emWeight = 0.10
}

/// Build a descriptor from a glyph outline.
func makeDescriptor(path: CGPath) -> ShapeDescriptor {
    let box = path.boundingBoxOfPath
    let bitmap = normalizedBitmap(path: path)
    let inked = bitmap.coverage.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
    let aspect = box.height > 0 ? Double(box.width / box.height) : 1
    // Every face this cascade reads is built at `makeCTFont`'s 1000pt size
    // (and so is the exemplar reference font), so path coordinates are points
    // on a 1000-unit em whatever the font's own design units are. SMuFL: the
    // em is the staff height, so one staff space is a quarter of it.
    let space = 250.0
    return ShapeDescriptor(
        bitmap: bitmap,
        aspectRatio: aspect,
        inkDensity: Double(inked) / Double(max(bitmap.coverage.count, 1)),
        flagPeaks: verticalProjectionPeaks(bitmap),
        emHeight: Double(box.height) / space,
        emBottom: Double(box.minY) / space,
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
