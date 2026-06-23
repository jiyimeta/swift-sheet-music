import CoreGraphics
import Foundation

extension PDFImporter {
    /// Distil straight horizontal path segments + `staff5Lines` glyphs
    /// into 5-line `Staff` records on a single page.
    static func detectStaves(
        paths: [PathSegment],
        classified: [ClassifiedGlyph],
        pageIndex: Int,
    ) -> [Staff] {
        let clusters = clusterHorizontals(paths, pageIndex: pageIndex)
        // Notehead origins on this page, used by `barlineCandidates` to
        // reject note stems by a font-independent geometric test (a stem
        // always has a notehead within ~one notehead width; a barline does
        // not). Captured once here and threaded down.
        let noteheads = classified.filter {
            $0.raw.pageIndex == pageIndex && isNotehead($0.semantic)
        }
        var staves = pathDetectedStaves(
            clusters: clusters,
            paths: paths,
            pageIndex: pageIndex,
            noteheads: noteheads,
        )
        appendGlyphDetectedStaves(
            classified: classified,
            paths: paths,
            pageIndex: pageIndex,
            noteheads: noteheads,
            into: &staves,
        )
        return staves.sorted { midline($0.yLines) < midline($1.yLines) }
    }

    // `midline(_:)` is shared from PDFImporter+Layout (internal static).

    /// Maximum midY distance for two co-linear horizontal segments to be
    /// treated as the SAME staff line. Must be **smaller than the staff
    /// line spacing** (the gap between adjacent lines of a 5-line staff),
    /// otherwise the five lines of one staff coalesce into a single
    /// cluster and the 5-window detector mis-reads three stacked staves as
    /// one tall band.
    ///
    /// Observed line spacing in MuseScore exports is ~4pt at this print
    /// size (and ~10pt at smaller sizes); the dashes that make up ONE line
    /// share a midY within ≤0.5pt. A 2pt tolerance safely coalesces the
    /// dashes of one line while keeping adjacent lines distinct even at the
    /// tightest spacing seen.
    private static let lineMergeTolerance: CGFloat = 2.0

    /// Filter horizontal segments on the page and cluster them by midY.
    /// Co-linear dash segments of one staff line coalesce; adjacent staff
    /// lines stay separate (see `lineMergeTolerance`).
    ///
    /// Width gate (>50pt) keeps decorative ledger / dot strokes out. lineWidth
    /// is intentionally NOT gated: real MuseScore PDFs report staff `w`
    /// operands ≥ ~1.8pt (MS3) or ≥ ~1pt (MS4), so any lineWidth threshold
    /// would either reject genuine staves or admit beams. The CV<0.1 5-window
    /// in `pathDetectedStaves` does the actual non-staff rejection.
    private static func clusterHorizontals(
        _ paths: [PathSegment],
        pageIndex: Int,
    ) -> [[PathSegment]] {
        let horiz = paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .horizontal
                && $0.rect.width > 50
        }
        var clusters: [[PathSegment]] = []
        for seg in horiz.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = clusters.last, let lastSeg = last.last,
               abs(seg.rect.midY - lastSeg.rect.midY) < lineMergeTolerance
            {
                clusters[clusters.count - 1].append(seg)
            } else {
                clusters.append([seg])
            }
        }
        return clusters
    }

    /// Slide a 5-window over consecutive y-clusters; CV < 0.1 ⇒ staff.
    private static func pathDetectedStaves(
        clusters: [[PathSegment]],
        paths: [PathSegment],
        pageIndex: Int,
        noteheads: [ClassifiedGlyph],
    ) -> [Staff] {
        var staves: [Staff] = []
        let lineYs: [CGFloat] = clusters.map { c in
            c.map(\.rect.midY).reduce(0, +) / CGFloat(c.count)
        }
        var i = 0
        while i + 4 < lineYs.count {
            let ys = Array(lineYs[i ... (i + 4)])
            if gapCV(ys) < 0.1 {
                let segs = (i ... (i + 4)).flatMap { clusters[$0] }
                let xMin = segs.map(\.rect.minX).min() ?? 0
                let xMax = segs.map(\.rect.maxX).max() ?? 0
                staves.append(makeStaff(
                    yLines: ys,
                    xRange: xMin ... xMax,
                    paths: paths,
                    pageIndex: pageIndex,
                    noteheads: noteheads,
                ))
                i += 5
            } else {
                i += 1
            }
        }
        return staves
    }

    /// Coefficient of variation of pairwise gaps in a y-sequence.
    private static func gapCV(_ ys: [CGFloat]) -> CGFloat {
        let gaps = zip(ys.dropFirst(), ys).map { $0 - $1 }
        guard !gaps.isEmpty else { return .infinity }
        let mean = gaps.reduce(0, +) / CGFloat(gaps.count)
        let variance = gaps
            .map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / CGFloat(gaps.count)
        return mean > 0 ? sqrt(variance) / mean : .infinity
    }

    /// Synthesise a staff from each `staff5Lines` glyph — but ONLY in
    /// regions where path detection found no staff. The glyph fallback
    /// exists for documents that draw the staff as one `U+E003` glyph
    /// instead of stroked lines; when stroked lines ARE present (the
    /// common case), the path detector is authoritative and the glyph
    /// must not add a near-duplicate staff offset by a few points.
    ///
    /// Dedup is therefore a **y-band overlap** test (not a midline match
    /// within 5pt): the glyph's origin.y may be a baseline rather than the
    /// optical midline, so an exact-midline test let a ~10pt-offset glyph
    /// slip past and create a phantom 6th staff per system.
    private static func appendGlyphDetectedStaves(
        classified: [ClassifiedGlyph],
        paths: [PathSegment],
        pageIndex: Int,
        noteheads: [ClassifiedGlyph],
        into staves: inout [Staff],
    ) {
        for g in classified where g.raw.pageIndex == pageIndex {
            guard case .staff5Lines = g.semantic else { continue }
            let yMid = g.raw.origin.y
            let lineSpacing = g.raw.fontSize / 4 // SMuFL design metric
            let ys = (0 ..< 5).map { yMid - lineSpacing * 2 + lineSpacing * CGFloat($0) }
            // Skip if this glyph's y-band overlaps any path-detected staff
            // (with a one-line-spacing slop for baseline/midline drift).
            let gLo = (ys.first ?? yMid) - lineSpacing
            let gHi = (ys.last ?? yMid) + lineSpacing
            let overlaps = staves.contains { s in
                let sLo = s.yLines.first ?? 0
                let sHi = s.yLines.last ?? 0
                return gLo <= sHi && sLo <= gHi
            }
            if overlaps { continue }
            let xMin = g.raw.origin.x
            let xMax = g.raw.origin.x + g.raw.advance
            staves.append(makeStaff(
                yLines: ys,
                xRange: xMin ... xMax,
                paths: paths,
                pageIndex: pageIndex,
                noteheads: noteheads,
            ))
        }
    }

    private static func makeStaff(
        yLines: [CGFloat],
        xRange: ClosedRange<CGFloat>,
        paths: [PathSegment],
        pageIndex: Int,
        noteheads: [ClassifiedGlyph],
    ) -> Staff {
        Staff(
            pageIndex: pageIndex,
            yLines: yLines,
            xRange: xRange,
            barlineCandidates: barlineCandidates(
                in: paths,
                xRange: xRange,
                yRange: (yLines.first ?? 0) ... (yLines.last ?? 0),
                pageIndex: pageIndex,
                noteheads: noteheads,
            ),
        )
    }

    private static func barlineCandidates(
        in paths: [PathSegment],
        xRange: ClosedRange<CGFloat>,
        yRange: ClosedRange<CGFloat>,
        pageIndex: Int,
        noteheads: [ClassifiedGlyph],
    ) -> [PathSegment] {
        // A true barline is a stand-alone vertical that SPANS the staff
        // height — from (near) the top line to (near) the bottom line.
        // The previous predicate merely required intersection, so every
        // note stem / ledger / bracket arm that crossed the staff band was
        // counted as a barline, inflating measure counts (observed: a
        // single system staff split into 79 "measures"). Require the
        // path's y-extent to cover ≥ 85% of the staff height and to reach
        // close to both the top and bottom staff lines.
        let staffHeight = yRange.upperBound - yRange.lowerBound
        guard staffHeight > 0 else { return [] }
        // The five staff lines span four inter-line gaps, so one staff space
        // (spatium) is a quarter of the staff height. All tolerances below
        // are expressed as multiples of this, NOT absolute points, so the
        // rule holds across print sizes and music fonts.
        let spatium = staffHeight / 4
        // Tolerance ≈ one inter-line gap — a barline may overshoot or fall
        // just short of the outer lines.
        let tol = max(spatium, 2)

        // FONT-INDEPENDENT stem rejection. The previous round gated on
        // stroke width (barline ≥ 1.3× staff-line width), calibrated to one
        // Leland score where bars were ~3.6pt and stems ~2.2pt. On MScore /
        // Bravura exports a note stem is strokes about as thick as a
        // barline, so that gate admitted stems as barlines → nearly every
        // note's stem became a measure boundary (observed: 君とParadiso
        // 112→633, 地球儀 62→440, カゲロウ 192→1921).
        //
        // The decisive, font-independent signal is the NOTEHEAD: a note stem
        // ALWAYS abuts its own notehead (within ~one notehead width), while a
        // real barline never has a notehead that close — the measure's last
        // note ends with the engraving right-margin before the bar, and the
        // next measure's first note opens after the bar's left margin. So a
        // vertical is a STEM (rejected) when a notehead origin lies just to
        // its LEFT (stem-up attaches at the notehead's right edge) or
        // essentially overlaps it (stem-down / chord). Empirically across the
        // corpus, stem noteheads sit ≤ ~1.3 spatium to the left while real
        // barlines have no notehead within ≥ ~3 spatium on that side; 2.0
        // spatium is a safe split. A tight right window (0.6 spatium) catches
        // stem-down / overlapping noteheads without rejecting a barline whose
        // next-measure note opens ~1.5 spatium to its right.
        let leftReject = spatium * 2.0
        let rightReject = spatium * 0.6
        // Notehead membership is restricted to this staff's own y-band
        // (≈ 3 ledger positions outside each outer line) so a neighbouring
        // staff's notes can't veto this staff's barlines.
        let yBand = spatium * 3
        let yLo = yRange.lowerBound - yBand
        let yHi = yRange.upperBound + yBand
        let staffNoteheads = noteheads.filter {
            $0.raw.origin.y >= yLo && $0.raw.origin.y <= yHi
        }

        return paths.filter { p in
            guard p.pageIndex == pageIndex, p.kind == .vertical,
                  xRange.contains(p.rect.midX)
            else { return false }
            let coverage = p.rect.height
            guard coverage >= staffHeight * 0.85 else { return false }
            // Endpoints must straddle the staff: top reaches near the upper
            // line, bottom reaches near the lower line.
            let reachesTop = p.rect.maxY >= yRange.upperBound - tol
            let reachesBottom = p.rect.minY <= yRange.lowerBound + tol
            guard reachesTop, reachesBottom else { return false }
            // Reject if a notehead abuts this vertical (⇒ it is a note stem).
            let x = p.rect.midX
            let hasAbuttingNotehead = staffNoteheads.contains { g in
                let d = g.raw.origin.x - x // + ⇒ notehead is right of vertical
                return d >= -leftReject && d <= rightReject
            }
            return !hasAbuttingNotehead
        }
    }
}
