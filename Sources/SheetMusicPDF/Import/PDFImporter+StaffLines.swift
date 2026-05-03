import CoreGraphics
import Foundation

extension PDFImporter {
    /// Distil straight horizontal path segments + `staff5Lines` glyphs
    /// into 5-line `Staff` records on a single page.
    static func detectStaves(
        paths: [PathSegment],
        classified: [ClassifiedGlyph],
        pageIndex: Int
    ) -> [Staff] {
        let clusters = clusterHorizontals(paths, pageIndex: pageIndex)
        var staves = pathDetectedStaves(
            clusters: clusters,
            paths: paths,
            pageIndex: pageIndex
        )
        appendGlyphDetectedStaves(
            classified: classified,
            paths: paths,
            pageIndex: pageIndex,
            into: &staves
        )
        return staves.sorted { midline($0.yLines) < midline($1.yLines) }
    }

    /// Median-position y of a `yLines` array (stable, simple, sufficient
    /// for "midline" comparisons).
    private static func midline(_ ys: [CGFloat]) -> CGFloat {
        ys.isEmpty ? 0 : ys[ys.count / 2]
    }

    /// Filter horizontal segments on the page and cluster them by midY using
    /// `~1.5 * lineWidth + 1` tolerance — co-linear segments coalesce.
    private static func clusterHorizontals(
        _ paths: [PathSegment],
        pageIndex: Int
    ) -> [[PathSegment]] {
        let horiz = paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .horizontal
                && $0.rect.width > 50
                && $0.lineWidth < 1
        }
        var clusters: [[PathSegment]] = []
        for seg in horiz.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = clusters.last, let lastSeg = last.last,
               abs(seg.rect.midY - lastSeg.rect.midY) < 1.5 * lastSeg.lineWidth + 1.0
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
        pageIndex: Int
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
                    pageIndex: pageIndex
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

    /// Synthesise a staff from each `staff5Lines` glyph; skip when an
    /// already-detected staff midline lies within 5pt.
    private static func appendGlyphDetectedStaves(
        classified: [ClassifiedGlyph],
        paths: [PathSegment],
        pageIndex: Int,
        into staves: inout [Staff]
    ) {
        for g in classified where g.raw.pageIndex == pageIndex {
            guard case .staff5Lines = g.semantic else { continue }
            let yMid = g.raw.origin.y
            if staves.contains(where: { abs(midline($0.yLines) - yMid) < 5 }) {
                continue
            }
            let lineSpacing = g.raw.fontSize / 4 // SMuFL design metric
            let ys = (0 ..< 5).map { yMid - lineSpacing * 2 + lineSpacing * CGFloat($0) }
            let xMin = g.raw.origin.x
            let xMax = g.raw.origin.x + g.raw.advance
            staves.append(makeStaff(
                yLines: ys,
                xRange: xMin ... xMax,
                paths: paths,
                pageIndex: pageIndex
            ))
        }
    }

    private static func makeStaff(
        yLines: [CGFloat],
        xRange: ClosedRange<CGFloat>,
        paths: [PathSegment],
        pageIndex: Int
    ) -> Staff {
        Staff(
            pageIndex: pageIndex,
            yLines: yLines,
            xRange: xRange,
            barlineCandidates: barlineCandidates(
                in: paths,
                xRange: xRange,
                yRange: (yLines.first ?? 0) ... (yLines.last ?? 0),
                pageIndex: pageIndex
            )
        )
    }

    private static func barlineCandidates(
        in paths: [PathSegment],
        xRange: ClosedRange<CGFloat>,
        yRange: ClosedRange<CGFloat>,
        pageIndex: Int
    ) -> [PathSegment] {
        paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .vertical
                && xRange.contains($0.rect.midX)
                && $0.rect.minY <= yRange.upperBound
                && $0.rect.maxY >= yRange.lowerBound
        }
    }
}
