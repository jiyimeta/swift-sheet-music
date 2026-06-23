import CoreGraphics
import Foundation

// System clustering: group a page's detected staves into systems.
//
// The robust path uses the left **bracket spine** that MuseScore draws
// down the left edge of every system; it cleanly delimits each system's
// y-extent even on dense vocal scores where staves within a system can
// sit nearly as far apart as two adjacent systems (which defeats any
// fixed `× staffHeight` gap threshold). The inter-staff-gap heuristic
// remains as a fallback for inputs without a detectable spine (e.g. the
// synthetic layout fixtures).

extension PDFImporter {
    /// A merged vertical run reconstructed from co-linear `.vertical`
    /// path segments at (almost) the same x. MuseScore draws a system's
    /// left bracket as a tall thick spine; barlines / stems are shorter
    /// or thinner. The spine cleanly delimits one system's y-extent.
    struct VerticalRun {
        var x: CGFloat
        var yLo: CGFloat
        var yHi: CGFloat
        var lineWidth: CGFloat
        var height: CGFloat {
            yHi - yLo
        }
    }

    /// Cluster page staves into systems by assigning each staff to the
    /// **bracket spine** whose y-extent contains it. Returns `nil` only when
    /// no usable spine is found (so the caller falls back to the gap
    /// heuristic).
    ///
    /// A staff whose midline isn't contained by any spine (with a one-
    /// staff-height slop) is assigned to the **nearest** spine by y-distance
    /// rather than aborting the whole page. MuseScore's bracket spine
    /// sometimes stops just inside the outer staff of a system (observed on
    /// 君とParadiso, where the topmost staff's midline sits ~30pt above the
    /// spine's top edge); bailing to the gap heuristic in that case shattered
    /// each staff into its own one-staff "system", which the assembler then
    /// stacked sequentially — inflating the measure count ~6×. Nearest-spine
    /// assignment keeps the correct multi-staff grouping.
    static func spineClusteredSystems(
        _ pageStaves: [Staff],
        paths: [PathSegment],
        pageIndex: Int,
    ) -> [[Staff]]? {
        guard !pageStaves.isEmpty else { return nil }
        let spines = bracketSpines(paths: paths, pageIndex: pageIndex)
        guard !spines.isEmpty else { return nil }
        // Group staves by the spine that vertically contains the staff's
        // midline; otherwise by the nearest spine.
        var groups: [Int: [Staff]] = [:]
        for staff in pageStaves {
            let mid = midline(staff.yLines)
            let h = staffHeight(staff)
            let slop = max(h, 8)
            let containing = spines.firstIndex {
                mid >= $0.yLo - slop && mid <= $0.yHi + slop
            }
            let si = containing ?? nearestSpineIndex(toMid: mid, spines: spines)
            groups[si, default: []].append(staff)
        }
        // Spines are unsorted; emit groups in page top→bottom order
        // (descending PDF y) to match the caller's expectation.
        let ordered = groups.keys.sorted { spines[$0].yHi > spines[$1].yHi }
        return ordered.map { si in
            (groups[si] ?? []).sorted { $0.yLines.first ?? 0 > $1.yLines.first ?? 0 }
        }
    }

    /// Index of the spine whose y-extent is closest to `mid` (distance 0
    /// when `mid` is inside the run, else the gap to the nearer edge).
    private static func nearestSpineIndex(
        toMid mid: CGFloat, spines: [VerticalRun],
    ) -> Int {
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, s) in spines.enumerated() {
            let dist: CGFloat = if mid < s.yLo {
                s.yLo - mid
            } else if mid > s.yHi {
                mid - s.yHi
            } else {
                0
            }
            if dist < bestDist {
                bestDist = dist
                best = i
            }
        }
        return best
    }

    /// Reconstruct tall, thick vertical "bracket spine" runs from the
    /// page's `.vertical` path segments. A spine is the system bracket's
    /// main line: line-width clearly above a hairline (> 4pt) and height
    /// spanning several staves (> 60pt). Co-linear segments at the same x
    /// (within 1pt) and contiguous in y (≤ 4pt gap) are merged first so a
    /// dashed / segment-split spine still reads as one run.
    private static func bracketSpines(
        paths: [PathSegment],
        pageIndex: Int,
    ) -> [VerticalRun] {
        let verticals = paths.filter {
            $0.pageIndex == pageIndex && $0.kind == .vertical && $0.rect.height > 10
        }
        let runs = mergeColinearVerticals(verticals)
        return runs.filter { $0.lineWidth > 4 && $0.height > 60 }
    }

    /// Merge `.vertical` segments sharing an x (rounded to 1pt) and
    /// contiguous in y into single runs. lineWidth becomes the max of the
    /// merged segments (a spine's thickest segment defines it).
    private static func mergeColinearVerticals(
        _ verticals: [PathSegment],
    ) -> [VerticalRun] {
        var byX: [Int: [PathSegment]] = [:]
        for v in verticals {
            byX[Int(v.rect.midX.rounded()), default: []].append(v)
        }
        var out: [VerticalRun] = []
        for (_, group) in byX {
            let sorted = group.sorted { $0.rect.minY < $1.rect.minY }
            guard var lo = sorted.first?.rect.minY,
                  var hi = sorted.first?.rect.maxY,
                  var lw = sorted.first?.lineWidth
            else { continue }
            let x = sorted[0].rect.midX
            for seg in sorted.dropFirst() {
                if seg.rect.minY <= hi + 4 {
                    hi = max(hi, seg.rect.maxY)
                    lw = max(lw, seg.lineWidth)
                } else {
                    out.append(VerticalRun(x: x, yLo: lo, yHi: hi, lineWidth: lw))
                    lo = seg.rect.minY
                    hi = seg.rect.maxY
                    lw = seg.lineWidth
                }
            }
            out.append(VerticalRun(x: x, yLo: lo, yHi: hi, lineWidth: lw))
        }
        return out
    }

    /// Group visually-adjacent staves into systems by inner y-gap. Input
    /// must already be sorted page top → bottom (i.e. by `yLines.first`
    /// descending in PDF y-up coords).
    ///
    /// On a page with enough staves to establish a typical spacing, the
    /// threshold is **data-driven**, not a fixed multiple of staff height.
    /// MuseScore opens up the gap between systems but the within-system
    /// inter-staff gap varies a lot by score (1.5–4× the staff height across
    /// this corpus). A fixed `1.5 × staffHeight` rule split every staff on
    /// the MScore-font scores (地球儀, カゲロウ) into its own one-staff
    /// "system" — which the assembler then stacked sequentially, inflating
    /// the measure count ~6–7×. Instead, take the MEDIAN inner gap (the
    /// typical within-system spacing) and break a system only where the gap
    /// exceeds `1.35 ×` that median. Because within-system gaps dominate, the
    /// median tracks them and the larger between-system gaps stand out
    /// regardless of font / print size.
    ///
    /// With too few staves for a reliable median (≤ 4 staves ⇒ ≤ 3 gaps —
    /// e.g. the synthetic layout fixtures), a single large gap would BE the
    /// median and defeat a far-staves split, so fall back to the staff-height
    /// rule: a gap below `1.5 × staffHeight` keeps the staves in one system.
    static func clusterIntoSystems(_ pageStaves: [Staff]) -> [[Staff]] {
        guard pageStaves.count > 1 else {
            return pageStaves.isEmpty ? [] : [pageStaves]
        }
        let gaps = zip(pageStaves.dropFirst(), pageStaves).map { lower, upper in
            innerGap(upper: upper, lower: lower)
        }
        let medianGap = median(gaps)
        // The median rule needs several gaps to be representative; use it
        // only with ≥ 4 gaps (≥ 5 staves). Otherwise fall back to a staff-
        // height multiple.
        let useMedian = gaps.count >= 4 && medianGap > 0
        let threshold = useMedian
            ? medianGap * 1.35
            : 1.5 * staffHeight(pageStaves[0])
        var systems: [[Staff]] = []
        for staff in pageStaves {
            if let prev = systems.last?.last,
               innerGap(upper: prev, lower: staff) <= threshold
            {
                systems[systems.count - 1].append(staff)
            } else {
                systems.append([staff])
            }
        }
        return systems
    }

    /// Median of a non-empty `[CGFloat]` (mean of the two middle elements
    /// for an even count). Returns 0 for an empty input.
    private static func median(_ xs: [CGFloat]) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n.isMultiple(of: 2) ? (s[n / 2 - 1] + s[n / 2]) / 2 : s[n / 2]
    }

    /// Inner vertical gap between two staves in PDF y-up coordinates:
    /// the empty band between the upper staff's lowest line and the
    /// lower staff's highest line.
    private static func innerGap(upper: Staff, lower: Staff) -> CGFloat {
        let upperBottom = upper.yLines.first ?? 0
        let lowerTop = lower.yLines.last ?? 0
        return upperBottom - lowerTop
    }
}
