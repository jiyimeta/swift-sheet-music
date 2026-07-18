#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

// System clustering: group a page's detected staves into systems.
//
// The robust path (`spineClusteredSystems`, in
// PDFImporter+SystemsSpanning.swift) uses the staff-spanning verticals
// MuseScore engraves at each system's left edge — the initial system
// barline and any bracket / brace line; they cleanly delimit each
// system's staves even on dense vocal scores where staves within a
// system can sit nearly as far apart as two adjacent systems (which
// defeats any fixed `× staffHeight` gap threshold). The inter-staff-gap
// heuristic in this file remains as a fallback for inputs without any
// vertical paths (e.g. the synthetic layout fixtures).

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

    /// Merge `.vertical` segments sharing an x (rounded to 1pt) and
    /// contiguous in y into single runs. lineWidth becomes the max of the
    /// merged segments (a spine's thickest segment defines it). Internal
    /// (not private) so the staff-spanning clustering in
    /// `PDFImporter+SystemsSpanning.swift` can reuse it.
    static func mergeColinearVerticals(
        _ verticals: [PathSegment],
    ) -> [VerticalRun] {
        var byX: [Int: [PathSegment]] = [:]
        for v in verticals {
            byX[Int(v.rect.midX.rounded()), default: []].append(v)
        }
        var out: [VerticalRun] = []
        // Emit runs in left→right x order: Dictionary iteration is hash-seed
        // dependent, and the run order feeds spine selection downstream
        // (`spineClusteredSystems` picks the FIRST containing spine).
        for (_, group) in byX.sorted(by: { $0.key < $1.key }) {
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
    /// Three tiers, most-specific first:
    ///
    /// 1. **Outlier-rank break (the robust path).** MuseScore stacks several
    ///    equal-sized systems per page; the between-system gap is a clear
    ///    OUTLIER above the within-system inter-staff gaps. A fixed
    ///    `median × 1.35` rule mis-fired on the MScore-font scores: their
    ///    within-system gaps spread wide (21–42pt on カゲロウ while the true
    ///    between-system gap is a flat ~49pt), so `median × 1.35` (~30–34pt)
    ///    was tripped by the larger within-system gaps and shattered one
    ///    8-staff system into 8/1/7 on half the pages. Instead, when a
    ///    document-wide `ensembleSize` E is known and the page's staff count
    ///    is a clean stack of E-staff systems, place the break at exactly the
    ///    `N/E − 1` LARGEST gaps — guarded so the smallest chosen break must
    ///    still be a clear outlier (≥ `breakOutlierFactor ×` the median of the
    ///    within-system gaps). Because the between-system gaps are the largest
    ///    AND clearly separated, this yields uniform E-staff systems on every
    ///    body page regardless of font / print size. A page whose staff count
    ///    is not a multiple of E (title pages, a partial final system) keeps
    ///    full E-staff systems from the top and lets the remainder form a
    ///    short final system.
    ///
    /// 2. **Per-page outlier fallback** (E unknown but ≥ 4 gaps). Break where
    ///    a gap exceeds `breakOutlierFactor ×` the median inner gap — the
    ///    median tracks the dominant within-system spacing, so only genuine
    ///    between-system gaps stand out. Used by direct single-page callers
    ///    that have no document context.
    ///
    /// 3. **Staff-height fallback** (≤ 3 gaps — e.g. the synthetic layout
    ///    fixtures). A single large gap would BE the median and defeat a
    ///    far-staves split, so a gap below `1.5 × staffHeight` keeps the
    ///    staves in one system. Left intact to guard those fixtures.
    static func clusterIntoSystems(
        _ pageStaves: [Staff],
        ensembleSize: Int? = nil,
    ) -> [[Staff]] {
        guard pageStaves.count > 1 else {
            return pageStaves.isEmpty ? [] : [pageStaves]
        }
        let gaps = zip(pageStaves.dropFirst(), pageStaves).map { lower, upper in
            innerGap(upper: upper, lower: lower)
        }

        // Tier 1 — document-wide ensemble size known: rank-break.
        if let breakIdxs = rankBreakIndices(gaps: gaps, ensembleSize: ensembleSize) {
            return splitAt(pageStaves, breakAfter: breakIdxs)
        }

        // Tiers 2 & 3 — threshold sweep (no ensemble prior).
        let medianGap = median(gaps)
        let useMedian = gaps.count >= 4 && medianGap > 0
        let threshold = useMedian
            ? medianGap * Self.breakOutlierFactor
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

    /// A gap is a system boundary when it exceeds `breakOutlierFactor ×` the
    /// typical (median) within-system gap. 1.35 separates the corpus's
    /// between-system gaps (≥ ~46pt, often 49–64) from within-system gaps
    /// (≤ ~42pt) on every observed page.
    private static let breakOutlierFactor: CGFloat = 1.35

    /// When a document-wide ensemble size E is known, return the set of gap
    /// indices to break AFTER so the page splits into E-staff systems (plus a
    /// short final system if the staff count isn't a clean multiple). Returns
    /// `nil` when E is unusable, the page is a single system, or the chosen
    /// breaks aren't clear outliers — in which case the caller falls back to
    /// the threshold sweep.
    ///
    /// `gaps[i]` is the inner gap between staff `i` and staff `i+1`.
    private static func rankBreakIndices(
        gaps: [CGFloat], ensembleSize: Int?,
    ) -> [Int]? {
        guard let e = ensembleSize, e >= 2 else { return nil }
        let staffCount = gaps.count + 1
        // Need at least two systems' worth of staves and enough gaps for the
        // outlier guard to mean something.
        guard staffCount > e, gaps.count >= 4 else { return nil }
        // Number of between-system boundaries: full E-staff systems give
        // (N / E − 1) interior breaks; a non-exact remainder adds one more
        // (the partial final system).
        let fullSystems = staffCount / e
        let nBreak = staffCount.isMultiple(of: e) ? fullSystems - 1 : fullSystems
        guard nBreak >= 1, nBreak < gaps.count else { return nil }
        // The nBreak largest gaps are the candidate system boundaries.
        let byMagnitude = gaps.indices.sorted { gaps[$0] > gaps[$1] }
        let breakSet = Set(byMagnitude.prefix(nBreak))
        let withinGaps = gaps.indices.filter { !breakSet.contains($0) }.map { gaps[$0] }
        let smallestBreak = breakSet.map { gaps[$0] }.min() ?? 0
        let withinMedian = median(withinGaps)
        // Guard: every chosen break must be a clear outlier above the
        // within-system population. Rejecting here means E doesn't actually
        // describe this page (e.g. a real single-system page), so defer to
        // the threshold sweep rather than force a wrong split.
        guard withinMedian > 0, smallestBreak >= withinMedian * Self.breakOutlierFactor
        else { return nil }
        return breakSet.sorted()
    }

    /// Split `staves` into consecutive groups, starting a new group after
    /// each index in `breakAfter` (gap-index `i` means "break between staff
    /// `i` and staff `i+1`").
    private static func splitAt(_ staves: [Staff], breakAfter: [Int]) -> [[Staff]] {
        let breaks = Set(breakAfter)
        var systems: [[Staff]] = [[]]
        for (i, staff) in staves.enumerated() {
            systems[systems.count - 1].append(staff)
            if breaks.contains(i) { systems.append([]) }
        }
        return systems.filter { !$0.isEmpty }
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
