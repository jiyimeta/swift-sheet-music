import CoreGraphics
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

    /// Number of beam lines crossing `stem`'s x at its beamed end.
    /// 0 ⇒ the note is not beamed (caller keeps the flag-based path).
    ///
    /// A beam segment counts when its x-extent overlaps the stem x (with a
    /// small slop, since the beam edge stops at the stem's center) and its
    /// y-range overlaps the stem's y-range (so a beam belonging to another
    /// staff or octave at the same x is not counted). MuseScore stacks beam
    /// lines ~3–4pt apart at the stem end, well within a stem's ~11–17pt
    /// reach, so every level over this stem overlaps it.
    static func beamLevelCount(
        stem: PathSegment,
        beams: [PathSegment],
    ) -> Int {
        let stemX = stem.rect.midX
        let stemLo = stem.rect.minY
        let stemHi = stem.rect.maxY
        // The beam edge is drawn to the stem centre, but the outermost
        // stem of a group can sit a few points beyond the beam's drawn
        // x-extent (the beam is inset to the stem's inner edge, and the
        // stem's measured midX carries the notehead-side offset). Allow
        // ~5pt — under the ~10pt note spacing, so it cannot reach a
        // non-adjacent stem.
        let xSlop: CGFloat = 5.0
        // A beam sits at the stem's END, but to tolerate the stem-line
        // y-extent being measured slightly short we accept any overlap of
        // the stem's full span padded by one beam thickness.
        let ySlop: CGFloat = 3.0
        var count = 0
        for beam in beams where beam.kind == .beam {
            let bxLo = beam.rect.minX - xSlop
            let bxHi = beam.rect.maxX + xSlop
            guard stemX >= bxLo, stemX <= bxHi else { continue }
            let byLo = beam.rect.minY - ySlop
            let byHi = beam.rect.maxY + ySlop
            // y-overlap between [byLo, byHi] and [stemLo, stemHi].
            guard byLo <= stemHi, stemLo <= byHi else { continue }
            count += 1
        }
        return count
    }

    /// True when a group-spanning beam strictly contains `stemX` (overruns
    /// it on BOTH sides by `margin`) and sits within ~one octave of stem
    /// reach of `noteY`. Used to recover a dropped PRIMARY beam for an
    /// interior note whose own stem vertical was mis-detected at the wrong
    /// y-row, WITHOUT counting partial/secondary beams (those terminate AT
    /// a stem, so they never strictly contain it). Returns the eighth level
    /// (1) when matched, else 0 — the primary beam is always the eighth
    /// level, so this only ever rescues an 8th, never inflates to a 16th.
    static func primaryBeamRescueLevel(
        stemX: CGFloat,
        noteY: CGFloat,
        beams: [PathSegment],
    ) -> Int {
        let maxBeamReach: CGFloat = 22.0
        let margin: CGFloat = 8.0
        for beam in beams where beam.kind == .beam {
            let strictInterior = stemX >= beam.rect.minX + margin
                && stemX <= beam.rect.maxX - margin
            let nearNote = beam.rect.midY >= noteY - maxBeamReach
                && beam.rect.midY <= noteY + maxBeamReach
            if strictInterior, nearNote { return 1 }
        }
        return 0
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
