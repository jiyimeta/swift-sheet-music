#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension RasterPage {
    /// How far apart two inked stretches of one staff line may be and
    /// still be merged, in staff spaces.
    ///
    /// MEASURED, not chosen. `Training/probes/measure_staff_ink.py` walks
    /// every truth staff line across the rasters and scores, for each
    /// candidate tolerance, whether ONE surviving piece still covers 80%
    /// of the line and clears `lineClusterWidthGate`. Over 6909 lines:
    ///
    ///     tolerance   clean     degraded
    ///     0.0 sp      0.9844    0.8369
    ///     0.5 sp      0.9844    0.9003
    ///     1.0 sp      0.9844    0.9091
    ///     2.0 sp      0.9844    0.9137
    ///     6.0 sp      0.9852    0.9223
    ///
    /// 1.0 sp costs nothing on clean input and buys 7.2 points on
    /// degraded input; past it the curve is a plateau worth under half a
    /// point, which does not pay for the extra reach into unrelated ink.
    /// Re-run that probe before changing this.
    static let staffLineGapToleranceInSpaces = 1.0

    /// Minimum width, in points, for a horizontal run to be a staff-line
    /// candidate.
    ///
    /// Points rather than staff spaces on purpose: this is the same gate
    /// the downstream vector code applies (`lineClusterWidthGate`), so
    /// emitting anything narrower would be emitting something
    /// `detectStaves` is going to discard anyway.
    static let staffLineMinWidthPt: Double = 50

    /// Least fraction of a merged run's span that must actually be inked.
    ///
    /// Without this the gap tolerance MANUFACTURES STAFF LINES. A row of
    /// ledger lines above a staff is a series of ~1.6-space marks about
    /// one note apart; each is far too short to be a staff-line candidate
    /// on its own, and the vector path leaves them as fragments that
    /// `lineClusterWidthGate` discards — but a 1.0-space gap tolerance
    /// bridges them into one run wide enough to pass. `detectStaves` then
    /// has six lines to fit a five-line window to, picks the top five,
    /// and every pitch on that staff moves by two steps.
    ///
    /// That was measured, not imagined: on `cov_accidentals` the raster
    /// staff came out as `[71.6, 76.4, 81.2, 86.2, 91.0]` against the
    /// oracle's `[76.3, 81.2, 86.0, 90.8, 95.7]` — the same window
    /// shifted up by exactly one line spacing — while measure counts,
    /// note counts and durations were all perfect.
    ///
    /// 0.75 is far below any real line and far above a bridged row of
    /// marks. Measured gap statistics put a degraded staff line's ink
    /// fraction above 0.99 (2.5 gaps per line at a 0.16-space median at
    /// 200dpi, 0.24 gaps at 2.8 spaces at 300dpi, over spans of ~100
    /// spaces), while ledger-line rows come out near 0.5.
    static let staffLineMinInkFraction = 0.75

    /// Least width, as a fraction of the widest horizontal run on the
    /// page, for a run to be a staff-line candidate.
    ///
    /// The ink-fraction gate is not enough on its own. Where notes are
    /// dense, a row of ledger lines is ~1.6-space marks about 2pt apart,
    /// so the bridged run is genuinely almost solid ink and clears any
    /// ink-fraction test. Measured on `tex_0064`: eight such rows one
    /// staff space apart, 91pt wide, between two real staves whose lines
    /// are 486–510pt wide. `detectStaves` was handed eight equally
    /// spaced lines to fit a five-line window to and produced FOUR
    /// staves where the page has three; the extra staff then takes
    /// content with it, and the score-level metrics read that as lost
    /// notes and lost measures.
    ///
    /// A local rule cannot separate these — measured, the longest
    /// unbroken stretch of a real degraded staff line has p05 = 0.075 of
    /// its span, while the ledger row reaches 0.09, so the two
    /// distributions overlap. What does separate them is CONTEXT: a
    /// staff line spans its system, and every staff line on a page is
    /// about as wide as every other. Page-relative rather than absolute
    /// so a page whose only system is short still keeps its staff.
    ///
    /// The cost is that a genuinely narrow staff — an ossia beside
    /// full-width systems — is discarded. Recorded rather than hidden.
    ///
    /// 0.20 is measured, and the window is NARROW at both ends. The
    /// ledger row this exists to reject sits at 91/500 = 0.182, so
    /// anything below that stops working; and a higher value starts
    /// discarding real staff lines. Swept on 177 renders:
    ///
    ///     fraction   pitch mean   measures exact   notes exact
    ///     (none)     44.4         119              92
    ///     0.20       46.6         130              91
    ///     0.25       46.6         124              86
    ///     0.35       46.6         117              83   (one render lost its staff entirely)
    ///
    /// Re-run the hybrid sweep before changing it; the pitch column alone
    /// does not show the damage, which is why the structural columns are
    /// recorded beside it.
    static let staffLineMinWidthFractionOfWidest = 0.20

    /// How wide a row of a line blob has to be, against the blob's widest
    /// row, to count as part of the LINE rather than as ink that merged
    /// into it.
    ///
    /// A staff line's blob is not always only the line. Where a beam, a
    /// slur or a dense row of noteheads presses against the line, the rows
    /// beside it also produce a run wide enough to clear
    /// `staffLineMinWidthPt`, and `blobs` merges those rows in — on ONE
    /// side, so the blob grows asymmetrically. Its yTop/yBottom midpoint
    /// then sits two to four raster rows away from the ink.
    ///
    /// The error is not cosmetic, because the downstream evenness gate
    /// prices it per STAFF: `pathDetectedStaves` keeps a five-line group
    /// only while `gapCV(ys) < 0.1`, so ONE displaced line among five
    /// costs all five. Measured on v2-eval, 27 of 574 staves were dropped
    /// with every one of their five lines emitted and exactly one of them
    /// off by 0.8–1.3pt against a 4.56pt spacing, while its neighbours
    /// stayed inside ±0.3pt.
    ///
    /// Loosening the gate is not the alternative: kept staves already
    /// reach cv 0.095, so the margin cannot absorb these without letting
    /// in groups that are not staves. The line has to be located
    /// correctly instead.
    ///
    /// 0.5 separates the two populations with room on both sides — a
    /// staff line spans its system, whereas the ink that touches it spans
    /// a beam or a chord — and the walk below is anchored on the widest
    /// row and CONTIGUOUS, so a wide run further down the blob cannot
    /// rejoin across the narrow rows that disowned it.
    static let staffLineCoreRowWidthFraction = 0.5

    /// Least fraction of a line blob's box that the agreement of its core
    /// rows must keep for that agreement to be believed — see
    /// `coreSpan(of:)`.
    ///
    /// MEASURED, and the measurement is the whole point: at 0.5 the
    /// v2-eval-frozen (degraded) staff-line recall falls 0.5415 → 0.4891,
    /// 226 lines, because an eroded row's ends are missing and the
    /// intersection believes them. Nothing downstream moved there — staves
    /// 448/447 aligned, barlines 8224/4703/2923 and beams 2049/7188/503 all
    /// identical — but a fifth of the line population shortening past the
    /// seam's 0.8 coverage gate is not a trade to make silently.
    ///
    /// The defect this exists to remove is small by construction: foreign
    /// ink reaches sideways only as far as `staffLineGapToleranceInSpaces`
    /// plus its own width, and measured on `tex_0017` that is 111px of a
    /// 2117px line — the intersection keeps 0.948 of the box. Erosion
    /// removes far more. 0.9 sits between them with room on both sides.
    static let staffLineCoreSpanFloor = 0.9

    /// Least fraction of the row projection's PEAK a row must reach to
    /// count as a staff-line row in `estimateStaffSpacingPx`.
    ///
    /// The old value was 0.5, and 0.5 has a measured failure: on
    /// `cov_flags` page 1 — four staves of nothing but 64th figures, all
    /// at the same pitch, so every flag blade repeats at the SAME y
    /// across the page width — the blade rows reach 0.4-0.5 of the peak,
    /// cross the threshold, and the median gap collapses from the staff
    /// line pitch (19px) to the blade pitch (12px). Every sp-denominated
    /// constant downstream inherits the broken spacing: the vertical
    /// length floor admits ~300 junk columns on that page (533 emitted
    /// against ~230 expected), junk competes for noteheads, and the
    /// render scores dur 48 / pitch 46 against an oracle-verticals 100.
    ///
    /// Row-count fractions on that page are bimodal with a wide gap —
    /// contaminating rows at 0.4-0.5 of peak (208 rows), true staff-line
    /// rows at 1.0 (45 rows), and only 5 rows in between — so the
    /// fraction sits in the middle of the empty band. All 69 clean
    /// v2-eval pages estimate correctly at every fraction in
    /// [0.55, 0.9]; 0.65 is a mid-plateau reading (the same rule the
    /// Otsu and deskew maxima needed), taken low enough to keep margin
    /// for degraded pages, whose eroded lines thin the peak rows.
    ///
    /// `OMR_ROW_PROJ_FRAC` overrides it for a sweep, the same way
    /// `OMR_VERTICAL_MIN_SP` overrides the vertical floor.
    static let rowProjectionPeakFraction =
        sweepOverride("OMR_ROW_PROJ_FRAC") ?? 0.65

    /// Staff-line spacing in pixels, from the row projection's peak
    /// spacing; nil when the page has no staff.
    ///
    /// Bootstrapping order matters. Every other threshold in this file is
    /// expressed in staff spaces, so spacing has to come from something
    /// that needs no threshold of its own — and a row projection needs
    /// none: measured against the labels it recovers 91-96% of staff
    /// lines by itself, which is far more than locating their spacing
    /// requires. (`rowProjectionPeakFraction` is relative to the page's
    /// own peak, not an absolute — the bootstrapping claim survives it.)
    /// `peakFraction` is a parameter (defaulted to the shipped constant)
    /// so a test can hold the blade-contamination mask fixed and flip
    /// only the threshold — the break-and-restore pair that proves the
    /// constant is load-bearing without mutating process environment.
    static func estimateStaffSpacingPx(
        _ mask: InkMask, peakFraction: Double = rowProjectionPeakFraction,
    ) -> Double? {
        var projection = [Int](repeating: 0, count: mask.height)
        for y in 0 ..< mask.height {
            var count = 0
            for x in 0 ..< mask.width where mask[x, y] {
                count += 1
            }
            projection[y] = count
        }
        guard let peak = projection.max(), peak > 0 else { return nil }
        let threshold = max(1, Int(Double(peak) * peakFraction))
        let centers = runCenters(projection, threshold: threshold)
        guard centers.count >= 2 else { return nil }

        var gaps: [Double] = []
        for i in 1 ..< centers.count {
            let gap = centers[i] - centers[i - 1]
            // Between-staff gaps are far larger than within-staff ones.
            // 40px is above every within-staff spacing measured on this
            // dataset (max 33.3px, at 400dpi) and below any gap between
            // two staves.
            if gap > 1, gap < 40 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    private static func runCenters(_ projection: [Int], threshold: Int) -> [Double] {
        var centers: [Double] = []
        var start: Int?
        for (y, count) in projection.enumerated() {
            if count >= threshold, start == nil {
                start = y
            } else if count < threshold, let from = start {
                centers.append(Double(from + y - 1) / 2)
                start = nil
            }
        }
        if let from = start { centers.append(Double(from + projection.count - 1) / 2) }
        return centers
    }

    /// Gap-tolerant horizontal runs, merged vertically into line blobs,
    /// emitted as `.horizontal` `PathSegment`s in page space.
    ///
    /// One segment per line — a DIFFERENT granularity from the vector
    /// front-end, which emits 1 to 10 segments per line. That is
    /// admissible only because `clusterHorizontals` merges co-linear
    /// segments downstream; it is also exactly why the gap merge has to
    /// happen HERE. `detectStaves` positions lines only from segments
    /// wider than `lineClusterWidthGate` = 50pt, so a line that arrives
    /// as ten 30pt fragments is not a slightly worse line, it is a line
    /// that does not exist.
    static func staffLineSegments(
        _ mask: InkMask, spacingPx: Double, transform: PageTransform, pageIndex: Int,
    ) -> [PathSegment] {
        let gapTolerance = max(1, Int((staffLineGapToleranceInSpaces * spacingPx).rounded()))
        let minWidthPx = max(1, Int((staffLineMinWidthPt * transform.dpi / 72.0).rounded()))
        var runsByRow: [[(x0: Int, x1: Int)]] = []
        runsByRow.reserveCapacity(mask.height)
        for y in 0 ..< mask.height {
            runsByRow.append(rowRuns(
                mask, y: y, gapTolerance: gapTolerance, minWidthPx: minWidthPx,
            ))
        }
        let found = blobs(runsByRow)
        let floor = referenceWidth(found) * staffLineMinWidthFractionOfWidest
        return found
            .filter { Double($0.x1 - $0.x0 + 1) >= floor }
            .map { segment(from: $0, transform: transform, pageIndex: pageIndex) }
    }

    /// The same blobs `staffLineSegments` emits, with the row-width
    /// profile each segment's y was derived from.
    ///
    /// `centerRow` is the only place a staff line's y is decided, and it
    /// decides it from `rowWidths` — a vector a caller cannot see through
    /// the `PathSegment` that comes out, whose `lineWidth` is the blob's
    /// whole box. A diagnostic that has to say WHY a line landed where it
    /// did therefore cannot work from the output alone. Exposed rather
    /// than copied into the test so the probe and the detector can never
    /// profile different blobs.
    struct BlobProfile {
        var segment: PathSegment
        var yTop: Int
        var yBottom: Int
        var centerRow: Double
        var rowWidths: [Int]
    }

    static func staffLineBlobProfiles(
        _ mask: InkMask, spacingPx: Double, transform: PageTransform, pageIndex: Int,
    ) -> [BlobProfile] {
        let gapTolerance = max(1, Int((staffLineGapToleranceInSpaces * spacingPx).rounded()))
        let minWidthPx = max(1, Int((staffLineMinWidthPt * transform.dpi / 72.0).rounded()))
        var runsByRow: [[(x0: Int, x1: Int)]] = []
        runsByRow.reserveCapacity(mask.height)
        for y in 0 ..< mask.height {
            runsByRow.append(rowRuns(
                mask, y: y, gapTolerance: gapTolerance, minWidthPx: minWidthPx,
            ))
        }
        let found = blobs(runsByRow)
        let floor = referenceWidth(found) * staffLineMinWidthFractionOfWidest
        return found
            .filter { Double($0.x1 - $0.x0 + 1) >= floor }
            .map {
                BlobProfile(
                    segment: segment(from: $0, transform: transform, pageIndex: pageIndex),
                    yTop: $0.yTop, yBottom: $0.yBottom,
                    centerRow: centerRow($0), rowWidths: $0.rowWidths,
                )
            }
    }

    /// The page's "a staff line is about this wide" reference: the median
    /// width of the widest quarter of the runs.
    ///
    /// NOT the maximum. A single full-page-width run — a page border, a
    /// frame rule — becomes the maximum and lifts the floor above the
    /// real staff lines of a small-format score, which measured as nine
    /// fewer renders with exact note counts. The widest quarter is a
    /// staff's own lines on any page that has a staff at all, and one
    /// outlier cannot move its median.
    private static func referenceWidth(_ found: [LineBlob]) -> Double {
        let widths = found.map { $0.x1 - $0.x0 + 1 }.sorted(by: >)
        guard !widths.isEmpty else { return 0 }
        let top = widths.prefix(max(1, widths.count / 4))
        return Double(top[top.count / 2])
    }

    /// Inked stretches of one row, with gaps up to `gapTolerance`
    /// bridged, keeping only those at least `minWidthPx` wide AND at
    /// least `staffLineMinInkFraction` inked.
    ///
    /// The ink fraction is what separates a broken staff line from a
    /// bridged row of ledger lines — see `staffLineMinInkFraction`.
    private static func rowRuns(
        _ mask: InkMask, y: Int, gapTolerance: Int, minWidthPx: Int,
    ) -> [(x0: Int, x1: Int)] {
        var out: [(x0: Int, x1: Int)] = []
        var start: Int?
        var lastInk: Int?
        var inked = 0
        func close(_ from: Int, _ last: Int, _ ink: Int) {
            let span = last - from + 1
            guard span >= minWidthPx,
                  Double(ink) >= staffLineMinInkFraction * Double(span)
            else { return }
            out.append((from, last))
        }
        for x in 0 ..< mask.width where mask[x, y] {
            if let last = lastInk, x - last > gapTolerance, let from = start {
                close(from, last, inked)
                start = x
                inked = 0
            } else if start == nil {
                start = x
                inked = 0
            }
            lastInk = x
            inked += 1
        }
        if let from = start, let last = lastInk { close(from, last, inked) }
        return out
    }
}
