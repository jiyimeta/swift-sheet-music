import CoreGraphics
import Foundation

extension PDFImporter {
    /// Cluster staves into systems and parts on a single page,
    /// then split each staff into measure cells by barline.
    ///
    /// `paths` is the unfiltered page-level path list (used to detect
    /// brackets / braces). `classified` is the page-level classified
    /// glyph list (used to bin glyphs into measure cells).
    ///
    /// Cross-staff barline alignment is applied **within each
    /// `ImportSystem`** (not just within each `ImportPart`). Two staves
    /// that share a system but disagree on barline midXs are re-split at
    /// the union of all barline midXs in the system, ensuring a uniform
    /// measure count across the system. This is a stronger guarantee
    /// than per-Part alignment and matches the plan's plain reading of
    /// "two staves in the same system must produce the same measure
    /// count".
    static func layoutSystems(
        staves: [Staff],
        paths: [PathSegment],
        classified: [ClassifiedGlyph],
        pageIndex: Int
    ) -> [ImportSystem] {
        let pageStaves = staves
            .filter { $0.pageIndex == pageIndex }
            .sorted { $0.yLines.first ?? 0 > $1.yLines.first ?? 0 }

        let systemGroups = clusterIntoSystems(pageStaves)
        return systemGroups.map { staffGroup -> ImportSystem in
            let parts = couplingByBracket(
                staves: staffGroup, paths: paths, pageIndex: pageIndex
            )
            let yRange = systemYRange(staffGroup)
            let bare = ImportSystem(pageIndex: pageIndex, yRange: yRange, parts: parts)
            return addingMeasures(bare, classified: classified)
        }
    }

    // MARK: - System clustering

    /// Visually-adjacent staves whose inner y-gap is < 1.5 × staff height
    /// belong to the same system. Input must already be sorted page top
    /// → bottom (i.e. by `yLines.first` descending in PDF y-up coords).
    private static func clusterIntoSystems(_ pageStaves: [Staff]) -> [[Staff]] {
        var systems: [[Staff]] = []
        for staff in pageStaves {
            if let prev = systems.last?.last,
               innerGap(upper: prev, lower: staff) < 1.5 * staffHeight(prev)
            {
                systems[systems.count - 1].append(staff)
            } else {
                systems.append([staff])
            }
        }
        return systems
    }

    /// Inner vertical gap between two staves in PDF y-up coordinates:
    /// the empty band between the upper staff's lowest line and the
    /// lower staff's highest line.
    private static func innerGap(upper: Staff, lower: Staff) -> CGFloat {
        let upperBottom = upper.yLines.first ?? 0
        let lowerTop = lower.yLines.last ?? 0
        return upperBottom - lowerTop
    }

    private static func staffHeight(_ s: Staff) -> CGFloat {
        guard let lo = s.yLines.first, let hi = s.yLines.last else { return 0 }
        return abs(hi - lo)
    }

    private static func systemYRange(_ group: [Staff]) -> ClosedRange<CGFloat> {
        // group is sorted top→bottom in PDF y-up coords. Top staff has
        // the largest y; bottom staff has the smallest.
        let topY = group.first?.yLines.last ?? 0
        let bottomY = group.last?.yLines.first ?? 0
        let lo = min(topY, bottomY)
        let hi = max(topY, bottomY)
        return lo ... hi
    }

    private static func midline(_ ys: [CGFloat]) -> CGFloat {
        ys.isEmpty ? 0 : ys[ys.count / 2]
    }

    // MARK: - Bracket coupling

    /// Vertical paths within ~5pt of the system's left x-edge whose
    /// y-extent covers the midline of two or more staves group those
    /// staves into a single `ImportPart` (grand staff). Otherwise each
    /// staff becomes its own part.
    private static func couplingByBracket(
        staves: [Staff], paths: [PathSegment], pageIndex: Int
    ) -> [ImportPart] {
        var coupled = Array(repeating: false, count: staves.count)
        var parts: [ImportPart] = []
        let leftX = staves.first?.xRange.lowerBound ?? 0
        let candidates = paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .vertical
                && abs($0.rect.midX - leftX) < 5
        }
        for path in candidates {
            let idxs = bracketCoupledIndices(path: path, staves: staves, coupled: coupled)
            guard idxs.count >= 2 else { continue }
            let group = idxs.map { ImportStaff(staff: staves[$0], measures: []) }
            parts.append(ImportPart(staves: group))
            for i in idxs { coupled[i] = true }
        }
        for (i, s) in staves.enumerated() where !coupled[i] {
            parts.append(ImportPart(staves: [ImportStaff(staff: s, measures: [])]))
        }
        return parts
    }

    private static func bracketCoupledIndices(
        path: PathSegment, staves: [Staff], coupled: [Bool]
    ) -> [Int] {
        var idxs: [Int] = []
        for (i, s) in staves.enumerated() where !coupled[i] {
            let mid = midline(s.yLines)
            if path.rect.minY <= mid && mid <= path.rect.maxY {
                idxs.append(i)
            }
        }
        return idxs
    }

    // MARK: - Measure splitting

    /// Decorate `system` with per-staff `[ImportMeasure]`. Uses the
    /// system-wide union of barline midXs so all staves in the system
    /// produce the same measure count.
    private static func addingMeasures(
        _ system: ImportSystem, classified: [ClassifiedGlyph]
    ) -> ImportSystem {
        let unionMidXs = systemBarlineUnion(system)
        var parts = system.parts
        for p in 0 ..< parts.count {
            for s in 0 ..< parts[p].staves.count {
                let staff = parts[p].staves[s].staff
                let xs = splitPoints(staff: staff, unionMidXs: unionMidXs)
                parts[p].staves[s].measures = makeMeasures(
                    staff: staff, splitXs: xs, classified: classified
                )
            }
        }
        return ImportSystem(pageIndex: system.pageIndex, yRange: system.yRange, parts: parts)
    }

    /// Sorted, deduplicated union of barline midXs across every staff in
    /// the system.
    private static func systemBarlineUnion(_ system: ImportSystem) -> [CGFloat] {
        var xs: [CGFloat] = []
        for part in system.parts {
            for importStaff in part.staves {
                xs.append(contentsOf: importStaff.staff.barlineCandidates.map(\.rect.midX))
            }
        }
        return dedupSorted(xs)
    }

    /// Sort + 1pt-coalesce — useful for both barline unions and the
    /// per-staff split list.
    private static func dedupSorted(_ xs: [CGFloat]) -> [CGFloat] {
        xs.sorted().reduce(into: [CGFloat]()) { acc, x in
            if acc.last.map({ abs($0 - x) > 1 }) ?? true { acc.append(x) }
        }
    }

    /// Per-staff cell boundaries: the union midXs that lie inside the
    /// staff's xRange, plus the staff xRange endpoints.
    private static func splitPoints(staff: Staff, unionMidXs: [CGFloat]) -> [CGFloat] {
        let lo = staff.xRange.lowerBound
        let hi = staff.xRange.upperBound
        let interior = unionMidXs.filter { $0 > lo && $0 < hi }
        return dedupSorted([lo] + interior + [hi])
    }

    private static func makeMeasures(
        staff: Staff, splitXs: [CGFloat], classified: [ClassifiedGlyph]
    ) -> [ImportMeasure] {
        guard splitXs.count >= 2 else { return [] }
        var measures: [ImportMeasure] = []
        let lastIndex = splitXs.count - 2
        for i in 0 ... lastIndex {
            let lo = splitXs[i]
            let hi = splitXs[i + 1]
            let cellGlyphs = filterGlyphs(classified: classified, staff: staff, lo: lo, hi: hi)
            measures.append(ImportMeasure(
                xRange: lo ... hi,
                glyphs: cellGlyphs,
                leadingBarline: i == 0 ? nil : barline(in: staff, near: lo),
                trailingBarline: i == lastIndex ? nil : barline(in: staff, near: hi)
            ))
        }
        return measures
    }

    private static func filterGlyphs(
        classified: [ClassifiedGlyph], staff: Staff, lo: CGFloat, hi: CGFloat
    ) -> [ClassifiedGlyph] {
        let yLo = (staff.yLines.first ?? 0) - 30
        let yHi = (staff.yLines.last ?? 0) + 30
        return classified.filter {
            $0.raw.pageIndex == staff.pageIndex
                && lo <= $0.raw.origin.x
                && $0.raw.origin.x < hi
                && yLo <= $0.raw.origin.y
                && $0.raw.origin.y <= yHi
        }
    }

    /// Pick a barline candidate from this staff's own list whose midX
    /// matches `x` within 1pt. Returns nil if no own candidate is near
    /// (e.g. the cell boundary came from another staff's barline via
    /// the system union).
    private static func barline(in staff: Staff, near x: CGFloat) -> PathSegment? {
        staff.barlineCandidates.first { abs($0.rect.midX - x) < 1 }
    }
}
