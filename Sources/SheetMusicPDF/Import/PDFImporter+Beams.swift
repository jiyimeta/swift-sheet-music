#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Beam-based rhythm. MuseScore renders each beam line as a filled
// near-horizontal parallelogram (`m l l l (h) f`); the content-stream
// walker captures those as `.beam` `PathSegment`s. The number of beam
// lines crossing a stem's x at the stem's beamed end gives the note's
// subdivision: 1 beam = eighth, 2 = sixteenth, 3 = thirty-second.
// Partial / fractional beams (a short hook on one stem of a
// dotted-eighth + sixteenth pair) are full `.beam` segments too — they
// simply do not span both neighbors, so the overlap test naturally
// counts them only for the stem they cover.

extension PDFImporter {
    /// Vertical band, in page coordinates, in which this staff's stems
    /// and beams live: the staff's line span padded by ~2 staff-heights
    /// on each side. Stem ends and the beam over them fall inside; the
    /// next staff (≈3 staff-heights away centre-to-centre on dense vocal
    /// scores) does not. Returns nil when the staff geometry is unusable
    /// (callers then skip the band gate).
    static func staffBeamBand(_ yLines: [CGFloat]) -> ClosedRange<CGFloat>? {
        guard let lo = yLines.first, let hi = yLines.last, hi > lo else {
            return nil
        }
        let h = hi - lo
        let pad = h * 2
        return (lo - pad) ... (hi + pad)
    }

    /// Whether `seg`'s y-range overlaps `band`. With no band (nil) the
    /// gate is a no-op (true) so degenerate staves still behave as before.
    static func segmentOverlapsBand(
        _ seg: PathSegment, _ band: ClosedRange<CGFloat>?,
    ) -> Bool {
        guard let band else { return true }
        return seg.rect.minY <= band.upperBound
            && seg.rect.maxY >= band.lowerBound
    }

    /// Map a beam-level count onto the note value reached by halving a
    /// quarter that many times: 1 ⇒ eighth, 2 ⇒ sixteenth, 3 ⇒
    /// thirty-second, etc. Levels ≤ 0 returns `base` unchanged so the
    /// caller can fall back to flags.
    static func durationForBeamLevels(_ levels: Int, base: NoteDuration) -> NoteDuration {
        guard levels > 0 else { return base }
        var d = base
        for _ in 0 ..< levels {
            d = halveDuration(d)
        }
        return d
    }

    /// One-step halving of a note value (quarter → eighth → …). Mirrors
    /// the private helper in PDFImporter+Rhythm so the beam pass is
    /// self-contained.
    static func halveDuration(_ d: NoteDuration) -> NoteDuration {
        switch d {
        case .whole: .half
        case .half: .quarter
        case .quarter: .eighth
        case .eighth: .sixteenth
        case .sixteenth: .thirtySecond
        case .thirtySecond: .sixtyFourth
        case .sixtyFourth: .oneTwentyEighth
        case .oneTwentyEighth: .twoFiftySixth
        case .twoFiftySixth: .twoFiftySixth
        case .measure: .measure
        case let .fraction(f):
            .fraction(Fraction(
                numerator: f.numerator,
                denominator: f.denominator * 2,
            ))
        }
    }
}
