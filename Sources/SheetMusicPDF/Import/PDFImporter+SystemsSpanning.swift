#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

// System clustering by staff-spanning verticals.
//
// MuseScore delimits every multi-staff system with engraved verticals at
// its left edge: the **initial system barline** — generated for every
// system with two or more staves, spanning the top staff's top line to
// the bottom staff's bottom line (mirrors `mu::engraving::System`; MS3
// `System::layoutSystem` creates it only when the system has more than
// one staff) — plus any bracket / brace group line. Three engraving
// invariants follow, and this file's clustering is built on exactly them:
//
//  1. A vertical run covering two or more staves' midlines joins staves
//     of ONE system (no engraved vertical ever crosses two systems), so
//     the connected components of "some run covers both staves" are the
//     page's systems.
//  2. A one-staff system gets NO initial system barline, so a staff that
//     no spanning run covers is a single-staff system. (The previous
//     thick-bracket heuristic returned nil for such pages and the
//     inter-staff-gap fallback then merged every staff on the page into
//     one giant "system" — the PART-EXPLODE failure on single-staff
//     scores, e.g. a 1-part bass sheet imported as 10 parts.)
//  3. Only the page FRAME (hairlines at x ≈ 0 / x ≈ page width spanning
//     the full page height, painted with whatever stale line width the
//     graphics state carried) overshoots the page's outermost staff
//     lines at BOTH ends; brackets and system barlines end at (or a
//     hair past) their own system's outer lines. Frame runs are page
//     furniture, never notation, and must not act as spines (they
//     previously collapsed a whole page into one 16-staff "system").
//
// No line-width gate: the initial system barline is a hairline and the
// old `lineWidth > 4` bracket gate rejected it, leaving dense vocal
// scores spine-less; their between-system gaps sit within noise of the
// within-system gaps, which defeats the gap fallback.

extension PDFImporter {
    /// Cluster page staves into systems by the staff-spanning verticals
    /// MuseScore draws (initial system barline, bracket / brace lines).
    /// Staves covered by a common run share a system; a staff covered by
    /// no run is its own single-staff system (see invariants above).
    ///
    /// Returns `nil` only when the page has no vertical path segments at
    /// all (the synthetic layout fixtures pass `paths: []`), so the
    /// caller falls back to the inter-staff-gap heuristic.
    static func spineClusteredSystems(
        _ pageStaves: [Staff],
        paths: [PathSegment],
        pageIndex: Int,
    ) -> [[Staff]]? {
        guard !pageStaves.isEmpty else { return nil }
        let verticals = paths.filter {
            $0.pageIndex == pageIndex && $0.kind == .vertical && $0.rect.height > 10
        }
        guard !verticals.isEmpty else { return nil }
        let runs = systemSpanningRuns(
            mergeColinearVerticals(verticals), staves: pageStaves,
        )
        return systemsByCoverage(pageStaves, runs: runs)
    }

    /// Runs that credibly join staves of one system: they cover at least
    /// two staves' midlines and do NOT overshoot the page's outermost
    /// staff lines on both ends (invariant 3 — the page frame does).
    private static func systemSpanningRuns(
        _ runs: [VerticalRun], staves: [Staff],
    ) -> [VerticalRun] {
        let topLine = staves.compactMap(\.yLines.last).max() ?? 0
        let bottomLine = staves.compactMap(\.yLines.first).min() ?? 0
        let frameTolerance = staves.map(staffHeight).max() ?? 8
        return runs.filter { run in
            if run.yLo < bottomLine - frameTolerance,
               run.yHi > topLine + frameTolerance
            {
                return false
            }
            return coveredStaffIndices(run: run, staves: staves).count >= 2
        }
    }

    /// Indices of staves whose midline lies inside the run's y-extent,
    /// with a one-staff-height slop per staff (a bracket sometimes stops
    /// just inside its system's outer staff).
    private static func coveredStaffIndices(
        run: VerticalRun, staves: [Staff],
    ) -> [Int] {
        staves.indices.filter { i in
            let mid = midline(staves[i].yLines)
            let slop = max(staffHeight(staves[i]), 8)
            return mid >= run.yLo - slop && mid <= run.yHi + slop
        }
    }

    /// Connected components of "some spanning run covers both staves"
    /// (invariant 1), emitted page top→bottom with staves top→bottom
    /// within each system. Uncovered staves stay singleton systems
    /// (invariant 2) unless a run's edge passes within 1.5 staff heights
    /// — MuseScore's bracket spine can stop just inside a system's outer
    /// staff (observed on 君とParadiso: the topmost staff's midline sits
    /// ~30pt above the spine's top edge). The bound keeps a genuinely
    /// separate single-staff system (a full between-system gap away)
    /// from being glued to its neighbour.
    private static func systemsByCoverage(
        _ staves: [Staff], runs: [VerticalRun],
    ) -> [[Staff]] {
        var uf = UnionFind(ids: Array(staves.indices))
        for run in runs {
            let covered = coveredStaffIndices(run: run, staves: staves)
            guard let first = covered.first else { continue }
            for other in covered.dropFirst() {
                uf.union(first, other)
            }
        }
        rescueNearMissStaves(staves, runs: runs, uf: &uf)
        var members: [Int: [Int]] = [:]
        for i in staves.indices {
            members[uf.find(i), default: []].append(i)
        }
        // Deterministic emission: order systems by their topmost staff's
        // top line (descending PDF y = page top first), ties by smallest
        // member index; order staves within a system top→bottom.
        let ordered = members.values.sorted { a, b in
            let ta = a.compactMap { staves[$0].yLines.last }.max() ?? 0
            let tb = b.compactMap { staves[$0].yLines.last }.max() ?? 0
            if ta != tb { return ta > tb }
            return (a.min() ?? 0) < (b.min() ?? 0)
        }
        return ordered.map { group in
            group
                .sorted { i, j in
                    let yi = staves[i].yLines.first ?? 0
                    let yj = staves[j].yLines.first ?? 0
                    if yi != yj { return yi > yj }
                    return i < j
                }
                .map { staves[$0] }
        }
    }

    /// Attach each staff that no run covers to the component of the run
    /// whose nearer y-edge is within 1.5 × its staff height (else leave
    /// it a singleton system). See `systemsByCoverage`.
    private static func rescueNearMissStaves(
        _ staves: [Staff], runs: [VerticalRun], uf: inout UnionFind,
    ) {
        for i in staves.indices {
            let mid = midline(staves[i].yLines)
            let slop = max(staffHeight(staves[i]), 8)
            let isCovered = runs.contains {
                mid >= $0.yLo - slop && mid <= $0.yHi + slop
            }
            guard !isCovered else { continue }
            var bestRun: VerticalRun?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for run in runs {
                let dist = mid < run.yLo ? run.yLo - mid : mid - run.yHi
                if dist < bestDist {
                    bestDist = dist
                    bestRun = run
                }
            }
            let bound = max(1.5 * staffHeight(staves[i]), 12)
            guard let bestRun, bestDist <= bound,
                  let anchor = coveredStaffIndices(run: bestRun, staves: staves).first
            else { continue }
            uf.union(i, anchor)
        }
    }
}
