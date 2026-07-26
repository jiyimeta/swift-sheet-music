#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension PDFImporter {
    // MARK: - Grand-staff (brace) coupling

    /// Group a system's staves into parts.
    ///
    /// MuseScore engraves a grand-staff instrument (piano / organ / harp)
    /// with a curly BRACE — the SMuFL `brace` glyph U+E000 — at the left
    /// margin of EVERY system, spanning the instrument's two staves. That
    /// glyph is the decisive, font-independent coupling signal: braced
    /// staves are one instrument (one `ImportPart`); every other staff is
    /// its own single-staff part.
    ///
    /// The previous rule coupled the two staves spanned by a left-edge
    /// vertical PATH. That never matches how MuseScore draws a system:
    /// (a) the initial system barline (and a bracket's stem) is emitted as
    /// per-staff SEGMENTS — each covering roughly one staff plus the gap
    /// below it — so a genuine grand staff is never spanned by one
    /// vertical and was never coupled (a solo piano imported as 2 parts);
    /// and (b) a square GROUP bracket over exactly two single-staff parts
    /// (a vocal pair) IS one two-staff vertical, so independent parts
    /// were wrongly merged into one, shifting every downstream part
    /// pairing (observed: 6 vocal parts imported as 5; an 11-part band
    /// score imported as 10 with the piano still split).
    ///
    /// Path-only inputs (the synthetic layout fixtures pass
    /// `classified: []`) carry no glyphs, so the brace signal does not
    /// exist there; the legacy vertical-span rule is kept for exactly
    /// that input shape.
    static func couplingIntoParts(
        staves: [Staff], paths: [PathSegment], classified: [ClassifiedGlyph],
        pageIndex: Int,
    ) -> [ImportPart] {
        let pageGlyphs = classified.filter { $0.raw.pageIndex == pageIndex }
        var coupled = Array(repeating: false, count: staves.count)
        var parts: [ImportPart] = []
        if pageGlyphs.isEmpty {
            legacyVerticalCoupling(
                staves: staves, paths: paths, pageIndex: pageIndex,
                coupled: &coupled, parts: &parts,
            )
        } else {
            braceCoupling(
                staves: staves, pageGlyphs: pageGlyphs,
                coupled: &coupled, parts: &parts,
            )
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

    /// Couple the two staves each brace glyph spans into one part.
    ///
    /// Geometry: MuseScore stretches the brace over the pair with a
    /// text-matrix scale, so the glyph's recorded fontSize is NOT a
    /// reliable y-extent. Its BASELINE is reliable: it sits at the braced
    /// pair's BOTTOM staff's bottom line (±~2pt across the corpus, i.e.
    /// well within half a staff height). Each brace therefore ANCHORS to
    /// the staff whose bottom line lies at its baseline and proposes
    /// coupling that staff with the one immediately ABOVE it (`staves`
    /// arrives sorted top→bottom). A brace belonging to another system
    /// fails the baseline test against every staff of this one; the x-gate
    /// (left of this system's staff start) drops an indented first
    /// system's brace from its neighbours.
    ///
    /// SEPARATION INVARIANT (rejects a group-BRACKET drawn as glyphs). A
    /// grand-staff brace consumes exactly two staves, so the anchor staves
    /// of a system's braces are always ≥ 2 indices apart (pair (0,1) and
    /// pair (2,3) ⇒ anchors 1 and 3). A **square group bracket** over N
    /// independent single-staff parts — which some fonts emit as a stack
    /// of per-staff brace-piece glyphs (observed: 革命前夜, a 6-vocal a
    /// cappella whose bracket classified as `.brace` at staff bottoms 1…5) —
    /// yields anchors at ADJACENT indices, which is impossible for
    /// non-overlapping grand staves. When any two anchors are adjacent the
    /// whole set is a bracket artifact, so no coupling is applied and each
    /// staff stays its own part.
    private static func braceCoupling(
        staves: [Staff], pageGlyphs: [ClassifiedGlyph],
        coupled: inout [Bool], parts: inout [ImportPart],
    ) {
        let leftX = staves.first?.xRange.lowerBound ?? 0
        let braces = pageGlyphs.filter {
            $0.semantic == .brace && $0.raw.origin.x < leftX
        }
        // Anchor every brace to its nearest staff bottom (within ½ staff).
        var anchors = Set<Int>()
        for brace in braces {
            let baseline = brace.raw.origin.y
            var best: (idx: Int, dist: CGFloat)?
            for (i, s) in staves.enumerated() {
                let dist = abs((s.yLines.first ?? 0) - baseline)
                if best.map({ dist < $0.dist }) ?? true { best = (i, dist) }
            }
            guard let hit = best, hit.idx >= 1,
                  hit.dist <= staffHeight(staves[hit.idx]) * 0.5
            else { continue }
            anchors.insert(hit.idx)
        }
        let sorted = anchors.sorted()
        let hasAdjacent = zip(sorted.dropFirst(), sorted).contains { $0 - $1 < 2 }
        guard !hasAdjacent else { return }
        for k in sorted where !coupled[k - 1] && !coupled[k] {
            parts.append(ImportPart(staves: [
                ImportStaff(staff: staves[k - 1], measures: []),
                ImportStaff(staff: staves[k], measures: []),
            ]))
            coupled[k - 1] = true
            coupled[k] = true
        }
    }

    /// Legacy fixture-compatibility rule for path-only documents: a
    /// vertical near the left x-edge spanning **exactly two** staff
    /// midlines couples them. (Three+ is a group bracket; one is a
    /// per-staff barline segment.) Real MuseScore exports never take this
    /// path — see `couplingIntoParts`.
    private static func legacyVerticalCoupling(
        staves: [Staff], paths: [PathSegment], pageIndex: Int,
        coupled: inout [Bool], parts: inout [ImportPart],
    ) {
        let leftX = staves.first?.xRange.lowerBound ?? 0
        let candidates = paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .vertical
                && abs($0.rect.midX - leftX) < 5
        }
        for path in candidates {
            var idxs: [Int] = []
            for (i, s) in staves.enumerated() where !coupled[i] {
                let mid = midline(s.yLines)
                if path.rect.minY <= mid, mid <= path.rect.maxY {
                    idxs.append(i)
                }
            }
            guard idxs.count == 2 else { continue }
            parts.append(ImportPart(
                staves: idxs.map { ImportStaff(staff: staves[$0], measures: []) },
            ))
            for i in idxs {
                coupled[i] = true
            }
        }
    }
}
