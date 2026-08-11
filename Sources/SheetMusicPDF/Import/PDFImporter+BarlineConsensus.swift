#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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
    /// cluster only when ≥ 2 distinct staves vote for it. The opening /
    /// closing system barlines appear in every staff, so they always clear
    /// the quorum.
    ///
    /// TWO staves are a quorum. This used to require three, on the reasoning
    /// that a barline "legitimately appears in just one or two staves" when
    /// there are only two — but a GRAND STAFF is exactly two staves, so every
    /// piano score fell back to the raw union and any single-staff vertical
    /// became a system-wide measure boundary. Measured on `疑事無功_piano`
    /// (55 measures of ground truth): the score contains exactly two
    /// single-staff verticals, `x=238 y=530..583 w=3.27` on one system's
    /// treble and `x=175 y=526..566 w=3.27` on another's bass, against real
    /// barlines that are `w=5.36` and span both staves. Those two carved two
    /// extra cells and shifted every later measure by one — positional pitch
    /// read 8% while the decode itself was correct, the shifted measures
    /// matching the ground truth exactly one index over. Every one of that
    /// score's real barlines appeared on BOTH staves.
    ///
    /// A SOLO staff still falls back to the raw union: there is nobody to
    /// agree with, and requiring a second vote would delete every barline it
    /// has.
    ///
    /// Upstream settles the two-staff question. `barLinesSetSpan`
    /// (`rendering/score/measurelayout.cpp:1559-1583`) walks every staff and
    /// CREATES a generated `BarLine` for any that lacks one; `barLineSpan`
    /// only decides whether the stroke visually joins down to the next
    /// staff, not whether the staff has a barline at all. So in
    /// MuseScore-derived output every real measure boundary strokes a
    /// vertical on both staves of a grand staff, `barLineSpan` 0 or 1 alike
    /// — and likewise for two separate one-staff parts, whose boundaries are
    /// system-aligned.
    ///
    /// WHAT THIS TRADES INTO, so the next diagnosis starts in the right
    /// place. A quorum can also delete a REAL barline, if one staff's vote
    /// is lost — and on two staves a single lost vote is now enough, where
    /// on three it takes two. The realistic way to lose one is the
    /// notehead veto in `PDFImporter+StaffLines` (a notehead within ~2sp to
    /// the left suppresses the candidate on that staff alone). Never
    /// observed: the 141-score corpus moved exactly one score when this gate
    /// dropped from 3 to 2, and that one improved. If a piano score ever
    /// shows MERGED measures, look there first.
    ///
    /// Genuinely unhandled either way, and unhandled before this too: per-
    /// staff invisible barlines, cutaway staves, an ossia detected as a
    /// second staff, and local (per-staff) time signatures. `addingMeasures`
    /// applies ONE union to every staff of the system, so the importer has
    /// no way to represent a staff with its own measure grid; the quorum
    /// only changes whether such a score comes out with extra measures or
    /// with merged ones.
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
        // A solo staff has nobody to agree with — keep the raw union.
        guard staffIndex >= 2 else { return rawUnion }
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
