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
    /// **bracket spine** whose y-extent contains it. Returns `nil` when no
    /// usable spine is found (so the caller falls back to the gap
    /// heuristic) or when any staff is left unassigned (a partial spine
    /// set would mis-group staves — better to fall back).
    static func spineClusteredSystems(
        _ pageStaves: [Staff],
        paths: [PathSegment],
        pageIndex: Int,
    ) -> [[Staff]]? {
        guard !pageStaves.isEmpty else { return nil }
        let spines = bracketSpines(paths: paths, pageIndex: pageIndex)
        guard !spines.isEmpty else { return nil }
        // Group staves by the spine that vertically contains the staff's
        // midline. A small slop absorbs the spine overshooting the outer
        // staff lines by up to one staff height.
        var groups: [Int: [Staff]] = [:]
        for staff in pageStaves {
            let mid = midline(staff.yLines)
            let h = staffHeight(staff)
            let slop = max(h, 8)
            guard let si = spines.firstIndex(where: {
                mid >= $0.yLo - slop && mid <= $0.yHi + slop
            }) else { return nil } // unassigned staff ⇒ fall back
            groups[si, default: []].append(staff)
        }
        // Spines are unsorted; emit groups in page top→bottom order
        // (descending PDF y) to match the caller's expectation.
        let ordered = groups.keys.sorted { spines[$0].yHi > spines[$1].yHi }
        return ordered.map { si in
            (groups[si] ?? []).sorted { $0.yLines.first ?? 0 > $1.yLines.first ?? 0 }
        }
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

    /// Visually-adjacent staves whose inner y-gap is < 1.5 × staff height
    /// belong to the same system. Input must already be sorted page top
    /// → bottom (i.e. by `yLines.first` descending in PDF y-up coords).
    static func clusterIntoSystems(_ pageStaves: [Staff]) -> [[Staff]] {
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
}
