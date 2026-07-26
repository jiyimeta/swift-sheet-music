#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

// F5 — heavily-justified final-bar recovery.
//
// MuseScore draws staff lines segmented PER MEASURE. The FINAL bar of a
// system is often justified to only a few staff spaces wide; its five
// staff-line segments are then too short to pass the conservative
// `lineClusterWidthGate` used for line clustering (admitting them there would
// risk a similarly-short non-staff decoration polluting the even-spacing CV
// test and dropping a whole staff). The result was that a staff's xRange
// stopped short of the system's closing barline, that barline was rejected by
// the per-staff membership test, and the final measure cell was never created
// — shifting every later measure by one (observed: 群青日和 page-0/system-1
// m5, which collapsed positional pitch to ~18%).
//
// The fix keeps line POSITION coming only from the wide clustered segments
// (robust), then EXTENDS each detected staff's xRange across the narrow
// staff-line segments that are co-linear with the staff's own lines — but only
// when they are contiguous with the wide span AND narrow enough (in staff
// spaces) to be a justified final bar rather than a normal line that merely
// fell below the absolute gate because the score's print size is small.

extension PDFImporter {
    /// Multiple of the page's median staff-line spacing below which a
    /// horizontal segment is too short to be a staff-line segment of a
    /// heavily-justified final bar (used by `extendXRangeWithNarrowSegments`
    /// only — NOT by line clustering). A real measure spans at least a few
    /// staff spaces; a ledger line / augmentation dot spans ~one. `4 ×`
    /// spacing lands inside the clean histogram valley between ledgers /
    /// dots (≤ ~2 spaces) and the narrowest justified staff segments
    /// (≥ ~6 spaces) observed across the corpus.
    private static let narrowStaffSegmentSpacingMultiple: CGFloat = 4

    /// Upper bound (in staff spaces) on the width of a narrow segment that
    /// may extend the xRange **without** a content check. A heavily-justified
    /// FINAL bar is drawn only a few staff spaces wide (≈ 6 — the minimum to
    /// show a whole note plus engraving margins), so segments up to this bound
    /// are accepted as justified-final-bar continuations purely on geometry
    /// (群青日和 m5's segments are ≈ 6 spaces). A WIDER co-linear contiguous
    /// segment can also be a real measure the wide-cluster gate dropped — e.g.
    /// a clef / key-change bar engraved a hair under the absolute clustering
    /// gate (observed: カゲロウ page-16 system-0, a real ~14-space measure with
    /// a treble clef + 3-sharp key signature + a notehead/rest in every staff,
    /// previously discarded here as a presumed phantom). Such wider segments
    /// are admitted only when `segmentRegionHasContent` confirms a notehead or
    /// rest sits in the staff band over the segment, distinguishing a real
    /// dropped measure from a content-free phantom margin past a closing
    /// barline. See `extendXRangeWithNarrowSegments`.
    private static let narrowStaffSegmentMaxSpacingMultiple: CGFloat = 8

    /// Maximum gap (in staff spaces) between the current xRange edge and a
    /// narrow staff-line segment for that segment to be treated as
    /// contiguous and extend the range. Sub-spatium so a barline-width gap
    /// is bridged but a real missing measure (≥ several spaces) is not.
    private static let xRangeExtendGapSlop: CGFloat = 1.0

    /// Estimate the page's staff-line spacing (one inter-line gap = one
    /// staff space / spatium) from the horizontal path segments. The wide
    /// segments (> a coarse 20pt floor that already excludes dots / ledgers)
    /// are clustered by midY exactly as the staff detector clusters them; the
    /// median of the small consecutive y-gaps between those clusters IS the
    /// line spacing (4 such gaps per 5-line staff dominate the population).
    /// Returns 0 when too few lines exist to estimate (callers fall back to
    /// an absolute floor).
    static func medianLineSpacing(_ pageHoriz: [PathSegment]) -> CGFloat {
        let wide = pageHoriz.filter { $0.rect.width > 20 }
        var midYs: [CGFloat] = []
        for seg in wide.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = midYs.last, abs(seg.rect.midY - last) < lineMergeTolerance {
                continue
            }
            midYs.append(seg.rect.midY)
        }
        // Keep only plausible inter-line gaps: positive, and below a generous
        // cap (30pt) so the large between-staff / between-system gaps don't
        // pollute the median.
        let gaps = zip(midYs.dropFirst(), midYs)
            .map { $0 - $1 }
            .filter { $0 > 0.5 && $0 < 30 }
            .sorted()
        guard !gaps.isEmpty else { return 0 }
        return gaps[gaps.count / 2]
    }

    /// Grow `xRange` to include the staff-line segments of a heavily-
    /// justified final bar that the conservative line-clustering gate dropped
    /// — but ONLY across segments **contiguous** with the staff's existing
    /// wide-line span AND narrow enough (in staff spaces) to be a justified
    /// final bar rather than a normal line below the absolute gate. A
    /// qualifying narrow segment:
    ///   * has width in `(narrowStaffSegmentSpacingMultiple × spacing,
    ///     narrowStaffSegmentMaxSpacingMultiple × spacing]` — wider than a
    ///     ledger line / dot (~1 space) yet no wider than a justified final
    ///     bar (~6-8 spaces), AND
    ///   * has its midY within `lineMergeTolerance` of one of the staff's
    ///     OWN line y's (so a decoration sitting between lines can't extend
    ///     the staff), AND
    ///   * butts against the current span: its x-interval is no farther than
    ///     `xRangeExtendGapSlop × spacing` beyond the current edge.
    ///
    /// Keying on the staff's own line y's, requiring contiguity, AND bounding
    /// the width in staff spaces makes this safe: it can only fill the gap to
    /// a real staff's own justified-narrow final bar (群青日和 m5: wide xMax
    /// ≈ 522.5, ~6-space segments to the closing barline at ≈ 552), never
    /// import a wider content region past a closing barline (カゲロウ).
    static func extendXRangeWithNarrowSegments(
        _ xRange: ClosedRange<CGFloat>,
        lineYs: [CGFloat],
        spacing: CGFloat,
        pageHoriz: [PathSegment],
        contentGlyphs: [ClassifiedGlyph] = [],
    ) -> ClosedRange<CGFloat> {
        guard spacing > 0 else { return xRange }
        let widthGate = spacing * narrowStaffSegmentSpacingMultiple
        let widthMax = spacing * narrowStaffSegmentMaxSpacingMultiple
        let gapSlop = spacing * xRangeExtendGapSlop
        // Candidate narrow staff-line segments co-linear with this staff.
        // A segment qualifies when it is wider than a ledger / dot
        // (`> widthGate`), still under the absolute line-clustering gate, and
        // co-linear with one of the staff's own lines. Up to `widthMax` staff
        // spaces it is accepted on geometry alone (a justified final bar);
        // wider co-linear segments are accepted only when a notehead / rest
        // sits over them in the staff band — a real dropped measure (e.g. a
        // clef / key-change bar), never a content-free phantom margin.
        let candidates = pageHoriz.filter { seg in
            guard seg.rect.width > widthGate,
                  seg.rect.width <= lineClusterWidthGate,
                  lineYs.contains(where: { abs(seg.rect.midY - $0) < lineMergeTolerance })
            else { return false }
            if seg.rect.width <= widthMax { return true }
            return segmentRegionHasContent(
                seg, lineYs: lineYs, spacing: spacing, content: contentGlyphs,
            )
        }
        var lo = xRange.lowerBound
        var hi = xRange.upperBound
        // Grow rightward, then leftward, each time only across a segment that
        // butts against (or overlaps) the current edge — so we never jump a
        // gap past the real closing / opening barline.
        var grew = true
        while grew {
            grew = false
            for seg in candidates {
                if seg.rect.minX <= hi + gapSlop, seg.rect.maxX > hi {
                    hi = seg.rect.maxX
                    grew = true
                }
                if seg.rect.maxX >= lo - gapSlop, seg.rect.minX < lo {
                    lo = seg.rect.minX
                    grew = true
                }
            }
        }
        return lo ... hi
    }

    /// True when a notehead or rest sits over `seg`'s x-interval within the
    /// staff's vertical band (the five lines ± ~3 staff spaces, the same band
    /// the cell glyph filter uses). Used to admit a WIDE co-linear staff-line
    /// segment past the wide-cluster span only when it carries real musical
    /// content — i.e. a measure the clustering gate dropped — and to reject a
    /// content-free phantom margin past a closing barline. Font-independent:
    /// the band is spatium-relative.
    private static func segmentRegionHasContent(
        _ seg: PathSegment,
        lineYs: [CGFloat],
        spacing: CGFloat,
        content: [ClassifiedGlyph],
    ) -> Bool {
        guard let lo = lineYs.first, let hi = lineYs.last else { return false }
        let band = spacing * 3
        let yLo = lo - band
        let yHi = hi + band
        return content.contains { g in
            g.geometry.origin.x >= seg.rect.minX
                && g.geometry.origin.x <= seg.rect.maxX
                && g.geometry.origin.y >= yLo
                && g.geometry.origin.y <= yHi
        }
    }
}
