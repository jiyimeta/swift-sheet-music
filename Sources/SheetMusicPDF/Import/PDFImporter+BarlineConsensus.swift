import CoreGraphics
import Foundation

extension PDFImporter {
    /// System-wide barline split points, by CONSENSUS across the system's
    /// staves rather than a raw union.
    ///
    /// A real barline is engraved straight down through the WHOLE system, so
    /// it appears at ~the same x in every staff. A spurious vertical that
    /// survives the per-staff notehead-veto — a tall beamed stem, a slur
    /// arm, a multi-stop bracket — typically shows up in a SINGLE staff. A
    /// raw union promoted any one staff's spurious vertical to a system-wide
    /// split, carving a real measure into two narrow content-bearing cells
    /// and shifting every following measure down (observed on ロビンソン:
    /// one staff's stray verticals at x≈106/183/535 inflated 89→92 measures,
    /// dragging positional pitch to 51% though the note decode was ~100%).
    ///
    /// Fix: cluster the candidates by x (≈ one staff space) and keep a
    /// cluster only when ≥ 2 distinct staves vote for it. Consensus needs a
    /// quorum, so it engages only for systems of ≥ 3 staves; 1-2 staff
    /// systems fall back to the raw union (a barline there legitimately
    /// appears in just one or two staves, and there aren't enough votes to
    /// tell a stray vertical from a real bar). The opening / closing
    /// system barlines appear in every staff, so they always clear the
    /// quorum.
    static func systemBarlineUnion(_ system: ImportSystem) -> [CGFloat] {
        var tagged: [(staff: Int, x: CGFloat)] = []
        var staffIndex = 0
        for part in system.parts {
            for importStaff in part.staves {
                for b in importStaff.staff.barlineCandidates {
                    tagged.append((staffIndex, b.rect.midX))
                }
                staffIndex += 1
            }
        }
        guard !tagged.isEmpty else { return [] }
        let rawUnion = dedupSorted(tagged.map(\.x))
        // Too few staves to form a quorum — keep the raw union (no
        // regression risk for solo / 2-staff systems).
        guard staffIndex >= 3 else { return rawUnion }
        let tol = barlineClusterTolerance(system)
        tagged.sort { $0.x < $1.x }
        var kept: [CGFloat] = []
        var i = 0
        while i < tagged.count {
            let start = tagged[i].x
            var staffVotes = Set<Int>()
            var sumX: CGFloat = 0
            var count = 0
            var j = i
            // A cluster spans at most `tol`, so distinct barlines (always
            // ≥ minCellWidth apart) never chain together.
            while j < tagged.count, tagged[j].x - start <= tol {
                staffVotes.insert(tagged[j].staff)
                sumX += tagged[j].x
                count += 1
                j += 1
            }
            if staffVotes.count >= 2 {
                kept.append(sumX / CGFloat(count))
            }
            i = j
        }
        return dedupSorted(kept)
    }

    /// Clustering tolerance for `systemBarlineUnion` — about one staff space,
    /// derived from the system's median staff height (spatium = height / 4)
    /// so it scales with print size and stays well below `minCellWidth`
    /// (real barlines are ≥ a measure apart, so this never merges two of
    /// them). Floored at 2pt for degenerate tiny staves.
    private static func barlineClusterTolerance(_ system: ImportSystem) -> CGFloat {
        var heights: [CGFloat] = []
        for part in system.parts {
            for importStaff in part.staves {
                let y = importStaff.staff.yLines
                if let lo = y.first, let hi = y.last {
                    heights.append(abs(hi - lo))
                }
            }
        }
        guard !heights.isEmpty else { return 3 }
        heights.sort()
        return max(heights[heights.count / 2] / 4, 2)
    }
}
