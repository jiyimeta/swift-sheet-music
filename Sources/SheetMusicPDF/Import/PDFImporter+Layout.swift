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
    /// `ensembleSize` is the document-wide system staff count (number of
    /// staves per system) derived in `buildScore` by `ensembleStaffCount`.
    /// When set, the gap-heuristic fallback uses it for outlier-rank system
    /// breaking (see `clusterIntoSystems`). The spine path, when available,
    /// still wins. Direct single-page callers (the layout fixtures) pass
    /// `nil`, preserving the staff-height / median fallbacks.
    static func layoutSystems(
        staves: [Staff],
        paths: [PathSegment],
        classified: [ClassifiedGlyph],
        pageIndex: Int,
        ensembleSize: Int? = nil,
    ) -> [ImportSystem] {
        let pageStaves = staves
            .filter { $0.pageIndex == pageIndex }
            .sorted { $0.yLines.first ?? 0 > $1.yLines.first ?? 0 }

        let systemGroups = spineClusteredSystems(pageStaves, paths: paths, pageIndex: pageIndex)
            ?? clusterIntoSystems(pageStaves, ensembleSize: ensembleSize)
        return systemGroups.map { staffGroup -> ImportSystem in
            let parts = couplingByBracket(
                staves: staffGroup, paths: paths, pageIndex: pageIndex,
            )
            let yRange = systemYRange(staffGroup)
            let bare = ImportSystem(pageIndex: pageIndex, yRange: yRange, parts: parts)
            return addingMeasures(bare, classified: classified)
        }
    }

    // MARK: - System / staff geometry helpers

    private static func systemYRange(_ group: [Staff]) -> ClosedRange<CGFloat> {
        // group is sorted top→bottom in PDF y-up coords. Top staff has
        // the largest y; bottom staff has the smallest.
        let topY = group.first?.yLines.last ?? 0
        let bottomY = group.last?.yLines.first ?? 0
        let lo = min(topY, bottomY)
        let hi = max(topY, bottomY)
        return lo ... hi
    }

    static func midline(_ ys: [CGFloat]) -> CGFloat {
        ys.isEmpty ? 0 : ys[ys.count / 2]
    }

    static func staffHeight(_ s: Staff) -> CGFloat {
        guard let lo = s.yLines.first, let hi = s.yLines.last else { return 0 }
        return abs(hi - lo)
    }

    // MARK: - Bracket coupling

    /// Group the system's staves into parts. A vertical near the left
    /// x-edge couples the staves it spans into one `ImportPart` — but
    /// ONLY when it spans **exactly two** staves, i.e. a grand-staff brace
    /// joining one instrument's two staves (piano / organ / harp).
    ///
    /// A vertical that spans three or more staves is a system **group
    /// bracket** (a square / line bracket grouping several otherwise
    /// independent single-staff parts — common in vocal / choral
    /// arrangements). It must NOT collapse those parts into one; doing so
    /// produced the 5-parts→1 regression. Such group brackets are skipped
    /// here, leaving each spanned staff its own part.
    private static func couplingByBracket(
        staves: [Staff], paths: [PathSegment], pageIndex: Int,
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
            // Exactly two spanned staves → grand-staff brace (couple).
            // One → a per-staff barline (ignore). Three+ → group bracket
            // over several single-staff parts (do NOT couple).
            guard idxs.count == 2 else { continue }
            let group = idxs.map { ImportStaff(staff: staves[$0], measures: []) }
            parts.append(ImportPart(staves: group))
            for i in idxs {
                coupled[i] = true
            }
        }
        for (i, s) in staves.enumerated() where !coupled[i] {
            parts.append(ImportPart(staves: [ImportStaff(staff: s, measures: [])]))
        }
        // Emit parts in page top→bottom order (descending PDF y) so the
        // per-part order is stable across systems for the assembler.
        return parts.sorted {
            ($0.staves.first?.staff.yLines.first ?? 0)
                > ($1.staves.first?.staff.yLines.first ?? 0)
        }
    }

    private static func bracketCoupledIndices(
        path: PathSegment, staves: [Staff], coupled: [Bool],
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
        _ system: ImportSystem, classified: [ClassifiedGlyph],
    ) -> ImportSystem {
        let unionMidXs = systemBarlineUnion(system)
        var parts = system.parts
        for p in 0 ..< parts.count {
            for s in 0 ..< parts[p].staves.count {
                let staff = parts[p].staves[s].staff
                let xs = splitPoints(staff: staff, unionMidXs: unionMidXs)
                parts[p].staves[s].measures = makeMeasures(
                    staff: staff, splitXs: xs, classified: classified,
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

    /// Minimum width for a measure cell. A split that would carve a cell
    /// narrower than this is a degenerate artifact (a final / double
    /// barline drawn as two near-coincident verticals at the staff's right
    /// edge), not a real measure boundary. Real measures on this corpus are
    /// ≥ 60pt wide; 16pt is a generous floor that never clips a true bar.
    private static let minCellWidth: CGFloat = 16

    /// Per-staff cell boundaries: the union midXs that lie inside the
    /// staff's xRange, plus the staff xRange endpoints. Split points closer
    /// than `minCellWidth` are coalesced so a double / final barline near
    /// the staff edge can't spawn a 1-3pt phantom measure (observed: the
    /// closing system split into 4 cells `[273, 228, 3, 1]` instead of 2,
    /// inflating the total measure count by 2).
    private static func splitPoints(staff: Staff, unionMidXs: [CGFloat]) -> [CGFloat] {
        let lo = staff.xRange.lowerBound
        let hi = staff.xRange.upperBound
        let interior = unionMidXs.filter { $0 > lo && $0 < hi }
        let all = dedupSorted([lo] + interior + [hi])
        return coalesceCloseSplits(all, hi: hi)
    }

    /// Greedily drop split points that would form a sub-`minCellWidth`
    /// cell. `lo` is always kept; the staff's right edge `hi` is always the
    /// final boundary (a near-edge interior split is snapped to it so the
    /// last real measure extends to the staff end).
    private static func coalesceCloseSplits(
        _ sorted: [CGFloat], hi: CGFloat,
    ) -> [CGFloat] {
        guard let first = sorted.first else { return sorted }
        var kept: [CGFloat] = [first]
        for x in sorted.dropFirst() {
            if x >= hi {
                // Ensure hi is the terminal boundary; if the last kept is
                // within minCellWidth of hi, replace it so we don't leave a
                // phantom sliver between it and the edge.
                if let last = kept.last, hi - last < minCellWidth, kept.count > 1 {
                    kept[kept.count - 1] = hi
                } else if kept.last != hi {
                    kept.append(hi)
                }
                continue
            }
            if let last = kept.last, x - last >= minCellWidth {
                kept.append(x)
            }
        }
        if kept.last != hi {
            if let last = kept.last, hi - last < minCellWidth, kept.count > 1 {
                kept[kept.count - 1] = hi
            } else {
                kept.append(hi)
            }
        }
        return kept
    }

    private static func makeMeasures(
        staff: Staff, splitXs: [CGFloat], classified: [ClassifiedGlyph],
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
                trailingBarline: i == lastIndex ? nil : barline(in: staff, near: hi),
                staffYLines: staff.yLines,
            ))
        }
        return measures
    }

    private static func filterGlyphs(
        classified: [ClassifiedGlyph], staff: Staff, lo: CGFloat, hi: CGFloat,
    ) -> [ClassifiedGlyph] {
        // Vertical capture band around the staff. A fixed ±30pt band
        // bled into the NEIGHBOURING staff on dense vocal scores where
        // staves sit only ~27pt apart center-to-center — every notehead of
        // the staff above/below was double-counted and decoded with the
        // wrong clef anchor (observed: parts 1-4 inflated to 450-566 notes
        // with impossible pitches up to MIDI 104). Scale the band to the
        // staff's own line spacing instead: ~3 ledger positions outside
        // each outer line captures legitimate ledgered notes without
        // reaching the next staff's lines.
        let bottom = staff.yLines.first ?? 0
        let top = staff.yLines.last ?? 0
        let lineSpacing = staff.yLines.count >= 2
            ? (top - bottom) / CGFloat(staff.yLines.count - 1)
            : 5
        let band = max(lineSpacing * 3, 6)
        let yLo = bottom - band
        let yHi = top + band
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
