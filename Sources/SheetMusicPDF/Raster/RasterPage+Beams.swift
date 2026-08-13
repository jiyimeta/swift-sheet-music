#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension RasterPage {
    /// Thickness of ONE beam, in staff spaces.
    ///
    /// Measured across 22,725 labelled beams and eight faces: p01 = 0.500,
    /// p50 = 0.500, p99 = 0.505, max = 0.510. It is effectively a
    /// constant, and it is also SMuFL's `engravingDefaults.beamThickness`,
    /// so the invariance is a property of engraving rather than of this
    /// dataset. (The 0.354 minimum is grace-size beams, 0.7 × the normal
    /// magnification — those still clear the k = 1 rung's tolerance.)
    static let beamSingleThicknessInSpaces = 0.5

    /// Vertical gap between two stacked beams, in staff spaces. Measured
    /// p05 = 0.246, p50 = 0.250, p95 = 0.250 over 9,426 stacked pairs —
    /// exactly half the thickness.
    static let beamGapInSpaces = 0.25

    /// Most beams that can be stacked: 64th notes. Beyond this the ladder
    /// rungs are closer together than the tolerance and the quantization
    /// stops discriminating.
    static let beamMaxLevels = 4

    /// Half-width of a ladder rung, in staff spaces and in pixels; the
    /// larger wins.
    ///
    /// Erosion and dilation move each outer edge by about a pixel, and a
    /// FUSED band has the same two outer edges as a single one, so the
    /// absolute pixel term matters most at 200dpi where a staff space is
    /// only 12.5px. The rungs are 0.75 sp apart, so even the widest
    /// tolerance here leaves a 0.35 sp dead zone between them — which is
    /// what keeps a notehead's ~1.0 sp column run from being read as a
    /// beam at all.
    static let beamThicknessToleranceInSpaces = 0.15
    static let beamThicknessTolerancePx = 2.5

    /// Shortest beam, in staff spaces. Measured min = p01 = 1.300 over
    /// 22,725 beams — the hook of a dotted-eighth pair — so a 1.5 sp gate
    /// would have discarded every one of them. 1.1 leaves room for
    /// erosion to shorten the ink.
    static let beamMinExtentInSpaces = 1.1

    /// Steepest beam. Measured max = 0.200, p99 = 0.146.
    static let beamMaxSlope = 0.25

    /// Worst allowed deviation of an edge from its straight-line fit, in
    /// staff spaces. Expressed in staff spaces, not pixels, so the same
    /// page content gets the same verdict at 200 and 400dpi.
    ///
    /// Swept through the hybrid on 198 renders (pitch p50 is 94 at every
    /// value):
    ///
    ///     value   dur p50   dur mean
    ///     0.08    76        64.7
    ///     0.12    78        64.9
    ///     0.20    78        65.4
    ///     0.30    78        65.7
    ///     0.50    78        65.7
    ///
    /// 0.30 and 0.50 are identical, so past 0.30 the gate rejects nothing
    /// at all and there is no plateau midpoint to take — the optimum is
    /// an unbounded interval. KEPT AT 0.12 anyway, and the 0.8 mean
    /// points above it are left on the table deliberately: every render
    /// here is CLEAN, and what this gate exists to reject is curved ink.
    /// Slurs are not detected at all yet, so on a page where one grazes a
    /// stem row a loose gate is what would let it through as a beam, and
    /// nothing in this sweep can see that. Re-measure on the frozen
    /// degraded set before spending the headroom.
    static let beamStraightnessInSpaces = 0.12

    /// How far a slab may run with no matching run before it is closed,
    /// in staff spaces.
    ///
    /// This bridges STEMS. A column where a stem crosses the beam has one
    /// merged run — beam plus the stem's whole length — which lands on no
    /// ladder rung, so without bridging every slab would end at every
    /// stem and beams would arrive as inter-stem fragments, most of them
    /// under `beamMinExtentInSpaces`. A stem is ~0.15 sp wide; 0.35 sp
    /// covers it with margin and is far below the shortest beam.
    static let beamBridgeInSpaces = 0.35

    /// Thin, straight, near-horizontal slabs, fitted into `BeamQuad`s,
    /// with fused stacks split back into their levels.
    ///
    /// Fusion is not a corner case: measured on this dataset, 2.40% of
    /// stacked beam pairs have an inked gap on a CLEAN raster and 7.27%
    /// after the scanner profile. And because a fused pair is 1.25 sp
    /// thick, a single-beam acceptance window would not merely read it as
    /// one beam — it would reject it outright and the whole group would
    /// lose every level, turning its notes into quarters.
    ///
    /// So fused and unfused stacks take the SAME path: a column run is
    /// accepted only when its thickness lands on the ladder
    /// `k·0.5 + (k−1)·0.25` for some k in 1…4, and the slab is then split
    /// into k. That also means the splitting logic is exercised by every
    /// stacked beam rather than only by the 2–7% that happen to fuse.
    static func beamSegments(
        _ mask: InkMask, spacingPx: Double, transform: PageTransform, pageIndex: Int,
    ) -> [PathSegment] {
        let slabs = linkSlabs(mask, spacingPx: spacingPx)
        let minExtentPx = beamMinExtentInSpaces * spacingPx
        var out: [PathSegment] = []
        for slab in slabs {
            for interval in constantLevelIntervals(slab) {
                guard let first = interval.first, let last = interval.last,
                      Double(last.x - first.x + 1) >= minExtentPx
                else { continue }
                out += quads(
                    for: interval, mask: mask, spacingPx: spacingPx,
                    transform: transform, pageIndex: pageIndex,
                )
            }
        }
        return out
    }

    /// One column's contribution to a slab: its run, and how many beam
    /// levels that run's thickness quantizes to.
    struct BeamColumn {
        var x: Int
        var y0: Int
        var y1: Int
        var levels: Int
    }

    /// Number of stacked beams a run of this length represents, or nil
    /// when it lands on no rung.
    static func beamLevels(runLengthPx: Double, spacingPx: Double) -> Int? {
        let tolerance = max(
            beamThicknessToleranceInSpaces * spacingPx,
            beamThicknessTolerancePx,
        )
        for k in 1 ... beamMaxLevels {
            let rung = ladderThicknessInSpaces(levels: k) * spacingPx
            if abs(runLengthPx - rung) <= tolerance { return k }
        }
        return nil
    }

    static func ladderThicknessInSpaces(levels k: Int) -> Double {
        Double(k) * beamSingleThicknessInSpaces
            + Double(k - 1) * beamGapInSpaces
    }

    /// Link ladder-quantized column runs into slabs, bridging the columns
    /// where a stem crosses.
    private static func linkSlabs(
        _ mask: InkMask, spacingPx: Double,
    ) -> [[BeamColumn]] {
        struct Open {
            var columns: [BeamColumn]
            var y0: Int
            var y1: Int
            var missing: Int
        }
        let bridgePx = max(1, Int((beamBridgeInSpaces * spacingPx).rounded()))
        var open: [Open] = []
        var closed: [[BeamColumn]] = []
        for x in 0 ..< mask.width {
            let runs = columnRuns(mask, x: x).compactMap { run -> BeamColumn? in
                guard let levels = beamLevels(
                    runLengthPx: Double(run.y1 - run.y0 + 1), spacingPx: spacingPx,
                ) else { return nil }
                return BeamColumn(x: x, y0: run.y0, y1: run.y1, levels: levels)
            }
            var next: [Open] = []
            var consumed = [Bool](repeating: false, count: runs.count)
            for var slab in open {
                var matched = false
                for (i, run) in runs.enumerated()
                    where !consumed[i] && run.y0 <= slab.y1 && run.y1 >= slab.y0
                {
                    slab.columns.append(run)
                    slab.y0 = run.y0
                    slab.y1 = run.y1
                    slab.missing = 0
                    consumed[i] = true
                    matched = true
                    break
                }
                if !matched { slab.missing += 1 }
                if slab.missing > bridgePx { closed.append(slab.columns) } else { next.append(slab) }
            }
            for (i, run) in runs.enumerated() where !consumed[i] {
                next.append(Open(columns: [run], y0: run.y0, y1: run.y1, missing: 0))
            }
            open = next
        }
        closed.append(contentsOf: open.map(\.columns))
        return closed
    }

    /// Maximal stretches of a slab whose columns agree on the level
    /// count, after a width-3 median smoothing.
    ///
    /// Splitting by level rather than taking one level for the whole slab
    /// is what handles PARTIAL SECONDARY BEAMS — a dotted-eighth/16th
    /// hook, or a secondary beam covering half a group, gives a slab that
    /// is genuinely 1.25 sp thick over part of its x-range and 0.5 over
    /// the rest. One level per slab would either reject the whole thing
    /// (its median landing in a dead zone) or invent a phantom second
    /// beam across the single-beam part.
    static func constantLevelIntervals(_ slab: [BeamColumn]) -> [[BeamColumn]] {
        guard slab.count >= 3 else { return slab.isEmpty ? [] : [slab] }
        var smoothed = slab
        for i in 1 ..< slab.count - 1 {
            var window = [slab[i - 1].levels, slab[i].levels, slab[i + 1].levels]
            window.sort()
            smoothed[i].levels = window[1]
        }
        var out: [[BeamColumn]] = []
        var current: [BeamColumn] = [smoothed[0]]
        for column in smoothed.dropFirst() {
            if column.levels == current[0].levels {
                current.append(column)
            } else {
                out.append(current)
                current = [column]
            }
        }
        out.append(current)
        return out
    }
}
