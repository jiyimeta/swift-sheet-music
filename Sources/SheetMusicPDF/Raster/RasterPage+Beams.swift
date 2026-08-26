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

    /// The rungs of a fused band, one per open slab it covers, or nil when
    /// the band is not that stack.
    ///
    /// The slabs' level counts must ALREADY sum to the band's own, and
    /// that is what keeps sharing from inventing a level: every rung handed
    /// out here was detected as a slab of its own by the columns on one
    /// side of the fusion, and the band's thickness independently agrees
    /// with their total. A run that merely grazes two slabs fails the sum
    /// and takes the ordinary single-slab path.
    ///
    /// The cuts are the fixed fractions `quads(for:)` places levels at, so
    /// a shared column lands where the band would have been split anyway
    /// had it stayed one slab; each rung must still meet the slab it is
    /// handed to, which rejects an implausible assignment outright.
    static func sharedRungs(
        of run: BeamColumn, across slabs: [(y0: Int, y1: Int, levels: Int)],
    ) -> [BeamColumn]? {
        guard slabs.count > 1,
              slabs.reduce(0, { $0 + $1.levels }) == run.levels
        else { return nil }
        let total = ladderThicknessInSpaces(levels: run.levels)
        let pitch = beamSingleThicknessInSpaces + beamGapInSpaces
        let top = Double(run.y0)
        let height = Double(run.y1 + 1 - run.y0)
        var out: [BeamColumn] = []
        var base = 0
        for slab in slabs {
            let fracTop = Double(base) * pitch / total
            let fracBottom = (Double(base + slab.levels - 1) * pitch
                + beamSingleThicknessInSpaces) / total
            let y0 = Int((top + fracTop * height).rounded())
            let y1 = Int((top + fracBottom * height).rounded()) - 1
            guard y0 <= y1, y0 <= slab.y1, y1 >= slab.y0 else { return nil }
            out.append(BeamColumn(x: run.x, y0: y0, y1: y1, levels: slab.levels))
            base += slab.levels
        }
        return out
    }

    /// Link ladder-quantized column runs into slabs, bridging the columns
    /// where a stem crosses and SHARING the columns where the stack's own
    /// ink merges.
    ///
    /// A merged column is one run for the whole stack, and handing it to a
    /// single slab is destructive twice over. The slabs it starves run out
    /// of bridge and close, and their remnants fall under
    /// `beamMinExtentInSpaces`; worse, the slab that took it now carries
    /// one column whose y-range is the whole band while
    /// `constantLevelIntervals`' median smoothing still calls the interval
    /// one level, and `quads` then fails that interval on straightness and
    /// drops it entire. ONE inked column across the 0.25 sp gap is enough
    /// to cost a two-beam group its outer beam outright, and
    /// `aSingleFusedColumnKeepsBothBeams` is that page.
    ///
    /// SHARING IS NOT WHAT THE CORPUS WAS LOSING, and that is the finding
    /// this comment exists to keep. The v2-eval signature — 114 of 199
    /// unmatched truth beams carrying a 0.5 sp prediction exactly one beam
    /// pitch away, the outer member missing three times in four — reads
    /// exactly like starvation, and it is not: sharing moved the seam
    /// ledger by nothing at all (levelMiss 315, absentMiss 222, fn 199, tp
    /// 2353 all unchanged; fp 376 -> 383) and every one of the 32 scorable
    /// renders came back with its duration and pitch percentages
    /// unchanged. So the merged column must already be arriving at a stage
    /// where only ONE slab is open — the stack fused from the first column
    /// of its shorter member, which never opens a second slab to share
    /// with — and the surviving 114 are being dropped somewhere after
    /// this function. Keep the non-destructive merge because it is right
    /// and cheap; do not credit it with corpus points it did not earn.
    private static func linkSlabs(
        _ mask: InkMask, spacingPx: Double,
    ) -> [[BeamColumn]] {
        let bridgePx = max(1, Int((beamBridgeInSpaces * spacingPx).rounded()))
        var open: [OpenSlab] = []
        var closed: [[BeamColumn]] = []
        for x in 0 ..< mask.width {
            let runs = ladderColumns(mask, x: x, spacingPx: spacingPx)
            var next: [OpenSlab] = []
            var consumed = [Bool](repeating: false, count: runs.count)
            let shares = fusedShares(runs: runs, open: open, consumed: &consumed)
            for (index, entry) in open.enumerated() {
                var slab = entry
                if let rung = shares[index] {
                    slab.take(rung)
                } else if let i = runs.indices.first(where: {
                    !consumed[$0] && runs[$0].y0 <= slab.y1 && runs[$0].y1 >= slab.y0
                }) {
                    slab.take(runs[i])
                    consumed[i] = true
                } else {
                    slab.missing += 1
                }
                if slab.missing > bridgePx { closed.append(slab.columns) } else { next.append(slab) }
            }
            for (i, run) in runs.enumerated() where !consumed[i] {
                next.append(OpenSlab(
                    columns: [run], y0: run.y0, y1: run.y1,
                    levels: run.levels, missing: 0,
                ))
            }
            open = next
        }
        closed.append(contentsOf: open.map(\.columns))
        return closed
    }

    /// A slab still being extended, column by column.
    private struct OpenSlab {
        var columns: [BeamColumn]
        var y0: Int
        var y1: Int
        var levels: Int
        var missing: Int

        mutating func take(_ column: BeamColumn) {
            columns.append(column)
            y0 = column.y0
            y1 = column.y1
            levels = column.levels
            missing = 0
        }
    }

    /// This column's ink runs, keeping only the ones whose thickness lands
    /// on a ladder rung.
    private static func ladderColumns(
        _ mask: InkMask, x: Int, spacingPx: Double,
    ) -> [BeamColumn] {
        columnRuns(mask, x: x).compactMap { run in
            guard let levels = beamLevels(
                runLengthPx: Double(run.y1 - run.y0 + 1), spacingPx: spacingPx,
            ) else { return nil }
            return BeamColumn(x: x, y0: run.y0, y1: run.y1, levels: levels)
        }
    }

    /// The rung each open slab is owed by a fused run this column, keyed by
    /// its index in `open`, marking every shared run consumed.
    ///
    /// Runs first, slabs second: a slab already promised a rung must not
    /// then be offered the same run again by the sequential pass, and a run
    /// already shared out must not be handed to a slab whole.
    private static func fusedShares(
        runs: [BeamColumn], open: [OpenSlab], consumed: inout [Bool],
    ) -> [Int: BeamColumn] {
        var shares: [Int: BeamColumn] = [:]
        for (i, run) in runs.enumerated() {
            let covered = open.indices
                .filter {
                    shares[$0] == nil
                        && run.y0 <= open[$0].y1 && run.y1 >= open[$0].y0
                }
                .sorted { open[$0].y0 < open[$1].y0 }
            guard let rungs = sharedRungs(
                of: run,
                across: covered.map { (open[$0].y0, open[$0].y1, open[$0].levels) },
            ) else { continue }
            for (slot, index) in covered.enumerated() {
                shares[index] = rungs[slot]
            }
            consumed[i] = true
        }
        return shares
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
