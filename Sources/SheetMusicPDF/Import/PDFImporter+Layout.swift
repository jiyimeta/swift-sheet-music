#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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
            let parts = couplingIntoParts(
                staves: staffGroup, paths: paths, classified: classified,
                pageIndex: pageIndex,
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

    // MARK: - Measure splitting

    /// Decorate `system` with per-staff `[ImportMeasure]`. Uses the
    /// system-wide union of barline midXs so all staves in the system
    /// produce the same measure count.
    private static func addingMeasures(
        _ system: ImportSystem, classified: [ClassifiedGlyph],
    ) -> ImportSystem {
        let unionMidXs = systemBarlineUnion(system)
        var parts = system.parts
        // Every staff band (outer-line y span) in the system, so each staff's
        // vertical glyph-capture band can be clamped at the MIDPOINT to its
        // nearest neighbour. On a tightly-spaced grand staff the fixed
        // ±3-line band otherwise reaches into the adjacent staff and
        // double-captures its noteheads (piano bass leaking into the treble).
        let bands = parts.flatMap { part in
            part.staves.map {
                (lo: $0.staff.yLines.min() ?? 0, hi: $0.staff.yLines.max() ?? 0)
            }
        }
        for p in 0 ..< parts.count {
            for s in 0 ..< parts[p].staves.count {
                let staff = parts[p].staves[s].staff
                let xs = splitPoints(staff: staff, unionMidXs: unionMidXs)
                parts[p].staves[s].measures = makeMeasures(
                    staff: staff, splitXs: xs, classified: classified,
                    bandClamp: neighborBandClamp(
                        top: staff.yLines.max() ?? 0,
                        bottom: staff.yLines.min() ?? 0, bands: bands,
                    ),
                )
            }
        }
        dropContentFreeNarrowCells(&parts)
        return ImportSystem(pageIndex: system.pageIndex, yRange: system.yRange, parts: parts)
    }

    /// A measure cell carries musical content when it contains at least one
    /// notehead OR one rest glyph. A cell with neither is not a real measure
    /// — on this corpus it is the engraving MARGIN sliver a heavily-justified
    /// final / double barline leaves between itself and the staff's right
    /// edge (the barline lands ~20-25pt shy of the staff line ends, wider
    /// than the `minCellWidth` floor, so it survives split coalescing as a
    /// phantom empty cell). Such a sliver shifts EVERY following measure of
    /// the score down by one cell, wrecking the positional per-measure
    /// comparison for the whole tail even though the note decode is correct.
    private static func measureHasContent(_ measure: ImportMeasure) -> Bool {
        for g in measure.glyphs {
            if isNotehead(g.semantic) { return true }
            if case .rest = g.semantic { return true }
        }
        return false
    }

    /// A spurious empty cell is dropped only when its width is below this
    /// fraction of the system's MEDIAN measure width. A real measure (even
    /// an empty-in-this-fixture one) is a full-width cell; the engraving
    /// margin a heavily-justified final / double barline leaves between
    /// itself and a staff edge — or a phantom sub-`minCellWidth`-adjacent
    /// fragment a double barline / repeat dots leaves mid-system — is a thin
    /// sliver (~20-25pt vs ~100pt+ real measures on the corpus).
    /// Measure-relative, so it holds across print sizes and fonts (and never
    /// fires on the synthetic layout fixtures, whose cells are full-width).
    private static let sliverWidthFraction: CGFloat = 0.5

    /// Drop every CONTENT-FREE NARROW measure cell — leading, internal, or
    /// trailing — uniformly across all staves of the system, so the
    /// per-system measure count stays consistent. This generalizes the
    /// earlier trailing-only sliver drop: a heavily-justified final / double
    /// barline, a repeat-barline's dot column, or a mid-system section break
    /// can leave a phantom empty sliver ANYWHERE in the cell list, and any one
    /// of those shifts every FOLLOWING measure down by one cell, wrecking the
    /// positional per-measure comparison for the tail even though the note
    /// decode is correct.
    ///
    /// A cell index is droppable iff, across EVERY staff of the system:
    ///   * it is CONTENT-FREE — no notehead AND no rest glyph in any staff
    ///     (`measureHasContent` is false everywhere). A legitimately empty
    ///     whole-rest bar HAS a rest glyph, so it is content-bearing and is
    ///     never dropped here.
    ///   * it is NARROW — width < `sliverWidthFraction` × the system's median
    ///     measure width. A full-width content-free cell (e.g. a real bar a
    ///     staff happens to leave blank) is NOT a sliver and is kept.
    /// The system must already carry REAL content somewhere (a wholly
    /// glyph-free system — the layout-only fixtures that pass `classified: []`,
    /// or a blank page — is left untouched), and at least one cell per staff
    /// always remains. Because every staff in a system shares the same split
    /// (the barline union), a cell's width and index are identical across
    /// staves, so removing the same index from all of them keeps the count
    /// uniform.
    private static func dropContentFreeNarrowCells(_ parts: inout [ImportPart]) {
        let systemHasContent = parts.contains { part in
            part.staves.contains { st in st.measures.contains(where: measureHasContent) }
        }
        guard systemHasContent else { return }
        let count = parts.flatMap { $0.staves.map(\.measures.count) }.max() ?? 0
        guard count >= 2 else { return }
        let widthGate = medianMeasureWidth(parts) * sliverWidthFraction
        guard widthGate > 0 else { return }
        // A cell index is droppable only when EVERY staff that reaches that
        // index agrees it is both content-free and narrow. Staves with fewer
        // cells (an under-segmented staff) can't veto, but if NO staff reaches
        // the index it isn't a real cell anyway.
        var dropIndices: [Int] = []
        for i in 0 ..< count {
            var present = false
            var allFreeNarrow = true
            for part in parts {
                for st in part.staves where i < st.measures.count {
                    present = true
                    let cell = st.measures[i]
                    let w = cell.xRange.upperBound - cell.xRange.lowerBound
                    if measureHasContent(cell) || w >= widthGate {
                        allFreeNarrow = false
                    }
                }
            }
            if present, allFreeNarrow { dropIndices.append(i) }
        }
        guard !dropIndices.isEmpty else { return }
        // Never drop a staff below one remaining cell.
        let dropSet = Set(dropIndices)
        for p in parts.indices {
            for s in parts[p].staves.indices {
                let kept = parts[p].staves[s].measures.enumerated()
                    .filter { !dropSet.contains($0.offset) }
                    .map(\.element)
                if !kept.isEmpty {
                    parts[p].staves[s].measures = kept
                }
            }
        }
    }

    /// Median width of all measure cells in the system (used to size the
    /// trailing-sliver gate). Zero when the system has no measures.
    private static func medianMeasureWidth(_ parts: [ImportPart]) -> CGFloat {
        var widths: [CGFloat] = []
        for part in parts {
            for st in part.staves {
                for m in st.measures {
                    widths.append(m.xRange.upperBound - m.xRange.lowerBound)
                }
            }
        }
        guard !widths.isEmpty else { return 0 }
        widths.sort()
        return widths[widths.count / 2]
    }

    /// Sort + 1pt-coalesce — useful for both barline unions and the
    /// per-staff split list. Internal (not file-private) so the
    /// barline-consensus helper in `PDFImporter+BarlineConsensus.swift` can
    /// reuse it.
    static func dedupSorted(_ xs: [CGFloat]) -> [CGFloat] {
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

    /// Vertical clamp bounds for a staff's glyph-capture band: the midpoint to
    /// the nearest staff below (`lower`) and above (`upper`). `±infinity` when
    /// there is no neighbour on that side. On a well-spaced ensemble the
    /// midpoint is farther than the ±3-line band, so clamping is a no-op; on a
    /// tight grand staff it stops the band from crossing into the sibling
    /// staff and double-capturing its noteheads.
    static func neighborBandClamp(
        top: CGFloat, bottom: CGFloat, bands: [(lo: CGFloat, hi: CGFloat)],
    ) -> (lower: CGFloat, upper: CGFloat) {
        var lower = -CGFloat.greatestFiniteMagnitude
        var upper = CGFloat.greatestFiniteMagnitude
        for b in bands {
            if b.hi < bottom - 0.5 {
                lower = max(lower, (bottom + b.hi) / 2)
            } else if b.lo > top + 0.5 {
                upper = min(upper, (top + b.lo) / 2)
            }
        }
        return (lower, upper)
    }

    private static func makeMeasures(
        staff: Staff, splitXs: [CGFloat], classified: [ClassifiedGlyph],
        bandClamp: (lower: CGFloat, upper: CGFloat) = (
            -CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude,
        ),
    ) -> [ImportMeasure] {
        guard splitXs.count >= 2 else { return [] }
        var measures: [ImportMeasure] = []
        let lastIndex = splitXs.count - 2
        for i in 0 ... lastIndex {
            let lo = splitXs[i]
            let hi = splitXs[i + 1]
            let cellGlyphs = filterGlyphs(
                classified: classified, staff: staff, lo: lo, hi: hi, clamp: bandClamp,
            )
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
        clamp: (lower: CGFloat, upper: CGFloat) = (
            -CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude,
        ),
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
        // Flag glyphs (E240–E24F) carry NO pitch — they only subdivide a
        // note's duration — so a wider capture band cannot corrupt pitch.
        // Drum flags in particular render ~10–13pt (≈0.75 staff-height)
        // beyond the outer lines, PAST the ±3-line pitch band, and were being
        // dropped: bare stems then read as quarters (地球儀 drums 16→q:19,
        // 君と kick 8→q). Admit flags out to ~6 line-spacings (still short of
        // the ~3-staff-height neighbour spacing); applyFlags' own staff-band
        // + x-gate contain any bleed this admits.
        let flagBand = max(lineSpacing * 6, 12)
        return classified.filter {
            guard $0.geometry.pageIndex == staff.pageIndex,
                  lo <= $0.geometry.origin.x,
                  $0.geometry.origin.x < hi
            else { return false }
            // Flags carry no pitch (they only subdivide a note's duration) and
            // render far from the staff, so their wide band must NOT be clamped
            // — clamping cut legitimate drum flags on tightly-spaced staves and
            // dropped their duration. Only the pitch-bearing band is clamped at
            // the midpoint to an adjacent staff, so a tight grand staff's
            // sibling noteheads aren't double-captured.
            if isFlag($0.semantic) {
                return (bottom - flagBand) <= $0.geometry.origin.y
                    && $0.geometry.origin.y <= (top + flagBand)
            }
            let low = max(bottom - band, clamp.lower)
            let high = min(top + band, clamp.upper)
            return low <= $0.geometry.origin.y && $0.geometry.origin.y <= high
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
