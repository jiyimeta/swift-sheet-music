import CoreGraphics
import Foundation
import SheetMusicCore

// GEOMETRY layer (① + ②) of the rhythm re-architecture. Replaces the
// axis-aligned bounding-box beam association (`beamLevelCount` +
// `primaryBeamRescueLevel` in PDFImporter+Beams) with sloped-quad,
// point-in-band membership, union-find beam groups, interior-inheritance,
// and pointing-direction partial-beam ownership.
//
// Why: a sloped beam's axis-aligned bbox inflates to ~7pt tall (the slope
// spans the x-range), so the old ±13pt y-window both (a) failed to reach a
// slightly-short interior stem (lost beams, 8→q) and (b) overlapped a
// vertically-aligned NEIGHBOUR-staff beam at the same x (over-read, 8→16 /
// q→16). The quad keeps the true ~2pt-thick parallelogram; membership is
// tested against the interpolated top / bottom edge at each stem's own x.

extension PDFImporter {
    // MARK: - Quad fitting (①)

    /// Fit a `BeamQuad` to the four page-space corners of a filled beam
    /// parallelogram. Splits the corners into a left pair and a right pair
    /// by x; within each pair the higher-y point is the top edge, the
    /// lower-y the bottom. Each edge (top / bottom) is the line through its
    /// left and right endpoints. Page coordinates (PDF origin bottom-left,
    /// y increases upward).
    static func fitBeamQuad(corners: [CGPoint], pageIndex: Int) -> BeamQuad? {
        guard corners.count == 4 else { return nil }
        let byX = corners.sorted { $0.x < $1.x }
        // Left pair = first two by x, right pair = last two. (A parallelogram
        // beam has two corners at each end.)
        let left = Array(byX[0 ... 1])
        let right = Array(byX[2 ... 3])
        let topLeft = left.max { $0.y < $1.y } ?? left[0]
        let botLeft = left.min { $0.y < $1.y } ?? left[0]
        let topRight = right.max { $0.y < $1.y } ?? right[0]
        let botRight = right.min { $0.y < $1.y } ?? right[0]
        guard let lo = corners.map(\.x).min(),
              let hi = corners.map(\.x).max(), hi > lo
        else { return nil }
        let (topSlope, topIntercept) = lineThrough(topLeft, topRight)
        let (botSlope, botIntercept) = lineThrough(botLeft, botRight)
        return BeamQuad(
            xRange: lo ... hi,
            topSlope: topSlope, topIntercept: topIntercept,
            botSlope: botSlope, botIntercept: botIntercept,
            pageIndex: pageIndex,
        )
    }

    /// Slope + intercept of the line through two points. Degenerate
    /// (coincident x) → flat line at the mean y.
    private static func lineThrough(
        _ p0: CGPoint, _ p1: CGPoint,
    ) -> (slope: CGFloat, intercept: CGFloat) {
        let dx = p1.x - p0.x
        guard abs(dx) > 0.001 else { return (0, (p0.y + p1.y) / 2) }
        let m = (p1.y - p0.y) / dx
        let b = p0.y - m * p0.x
        return (m, b)
    }

    // MARK: - Point-in-band membership (②)

    /// The pad (pt) added around a quad's interpolated top / bottom edge
    /// when testing whether a stem end falls inside the ~2pt-thick beam
    /// band (used by partial-stub ownership). Wide enough to catch a
    /// slightly-short / off-row stem, far too narrow to reach a wrong-staff
    /// stem ~100pt away.
    static let beamBandPad: CGFloat = 4.0
    /// Slop (pt) on a quad's x-range when testing a stem's x against it
    /// (used by partial-stub ownership).
    static let beamXPad: CGFloat = 3.0

    /// Generous reach (pt) for full-beam membership: a stem whose x is
    /// horizontally spanned by a full beam and whose nearer end sits within
    /// this distance of the beam's interpolated edge belongs to that beam's
    /// group at this level. Wider than the strict band (`beamBandPad`) so a
    /// slightly-short / off-row interior stem is still grouped, yet under the
    /// ~24pt that would reach a wrong-octave beam on the same staff.
    static let beamReach: CGFloat = 15.0

    /// Tight endpoint pad (pt) for full-beam membership. A beam's x-range
    /// endpoints coincide with its OUTERMOST group stems, so a real member
    /// sits within ~1pt of the span; the very next note (a different chord)
    /// is ~one notehead-gap (≈ 3pt+) beyond. A small pad therefore includes
    /// the outer group stems without absorbing the trailing note — the cause
    /// of a quarter after a 16th run being over-read as a sixteenth.
    static let beamEndpointPad: CGFloat = 1.5

    /// Whether a FULL `beam` horizontally spans `stem`'s x AND lies within
    /// `beamReach` of one of the stem's ends — the membership criterion used
    /// both for group union-find and for counting stacked beam levels. The
    /// x-test uses the tight `beamEndpointPad` so a note just before / after
    /// a group is not pulled in.
    static func fullBeamSpans(
        _ beam: PathSegment, stem s: StemInfo,
    ) -> Bool {
        guard let q = beam.quad else {
            return s.x >= beam.rect.minX - beamEndpointPad
                && s.x <= beam.rect.maxX + beamEndpointPad
                && min(abs(s.hiY - beam.rect.midY), abs(s.loY - beam.rect.midY)) <= beamReach
        }
        guard s.x >= q.xRange.lowerBound - beamEndpointPad,
              s.x <= q.xRange.upperBound + beamEndpointPad
        else { return false }
        let edgeMid = (q.topY(at: s.x) + q.botY(at: s.x)) / 2
        let dTop = abs(s.hiY - edgeMid)
        let dBot = abs(s.loY - edgeMid)
        return min(dTop, dBot) <= beamReach
    }

    /// Looser y-reach (pt) used ONLY for GROUP membership (interior
    /// inheritance), not level counting. A stem whose x falls strictly
    /// inside a full beam's horizontal span is geometrically under that beam
    /// and belongs to its group even when its measured end band-misses the
    /// edge by more than `beamReach`. Bounded so a wrong-octave note in the
    /// same x-span (≈ a 7th / octave away) is not pulled in. Mirrors the old
    /// `primaryBeamRescueLevel` reach (22) plus a touch of slack.
    static let beamGroupReach: CGFloat = 24.0
    /// Interior margin (pt) a stem must sit inside a full beam's x-range to
    /// count as an interior group member (so an endpoint stem at the very
    /// edge — possibly the start of a *different* group — is not absorbed).
    static let beamGroupInteriorMargin: CGFloat = 2.0

    /// Whether `stem` is an INTERIOR member of a full `beam`'s group: its x
    /// sits strictly inside the beam's horizontal span and one of its ends
    /// is within `beamGroupReach` of the beam edge. Used to union band-miss
    /// stems into the group so interior inheritance can floor them at the
    /// primary (eighth) level.
    static func stemInBeamGroup(
        _ beam: PathSegment, stem s: StemInfo,
    ) -> Bool {
        let lo: CGFloat
        let hi: CGFloat
        let edgeMid: CGFloat
        if let q = beam.quad {
            lo = q.xRange.lowerBound
            hi = q.xRange.upperBound
            edgeMid = (q.topY(at: s.x) + q.botY(at: s.x)) / 2
        } else {
            lo = beam.rect.minX
            hi = beam.rect.maxX
            edgeMid = beam.rect.midY
        }
        guard s.x >= lo + beamGroupInteriorMargin,
              s.x <= hi - beamGroupInteriorMargin
        else { return false }
        return min(abs(s.hiY - edgeMid), abs(s.loY - edgeMid)) <= beamGroupReach
    }

    // MARK: - Beam groups + per-stem level (③)

    /// One stem to feed the beam-group solver: its index in the measure's
    /// `stems` array, its x, and its vertical span.
    struct StemInfo {
        var index: Int
        var x: CGFloat
        var loY: CGFloat
        var hiY: CGFloat
    }

    /// Per-stem beam level (number of beam lines stacked over the stem at
    /// its x), with two corrections beyond a raw covering count:
    ///
    /// 1. INTERIOR-INHERITANCE: any stem in a beam GROUP of size ≥ 2 whose
    ///    own covering-count is 0 still gets level ≥ 1 — every member of a
    ///    beam group is beamed at least at the eighth (primary) level. This
    ///    subsumes the old `primaryBeamRescueLevel` with a real invariant.
    /// 2. PARTIAL-BEAM OWNERSHIP: a stub (short quad touching one stem,
    ///    pointing toward it) adds a secondary level only to its owner. This
    ///    separates a dotted-eighth (primary only) from its sixteenth
    ///    neighbour (primary + owned stub).
    ///
    /// Groups are union-find components over stems joined by a shared
    /// FULL (group-spanning) beam.
    static func beamLevels(
        stems: [StemInfo], beams: [PathSegment],
    ) -> [Int: Int] {
        let quadBeams = beams.filter { $0.kind == .beam }
        // Classify each beam by the stems it spans, NOT by absolute width:
        // a FULL beam covers ≥ 2 stems (a group-spanning primary or a
        // multi-stem secondary); a STUB (fractional / partial beam) covers
        // exactly one. An earlier width-vs-median-gap heuristic mis-filed a
        // genuine 2-stem beam in a sparse measure as a stub (large median
        // gap → high width threshold), dropping its primary level (8→q).
        var fullBeams: [PathSegment] = []
        var stubBeams: [PathSegment] = []
        for b in quadBeams {
            let spanned = stems.count(where: { fullBeamSpans(b, stem: $0) })
            if spanned >= 2 {
                fullBeams.append(b)
            } else {
                stubBeams.append(b)
            }
        }

        // Per-stem count of FULL beams that horizontally span it (primary +
        // any secondary full beams covering its x). A full beam between two
        // 16ths spans only those stems, so an eighth in the same run is
        // counted once (primary) and a 16th twice (primary + secondary).
        // `fullBeamSpans` uses a generous y-reach so a slightly-short /
        // off-row interior stem is not dropped — the cause of the prior
        // 8→q misses with a strict ~2pt band.
        var fullCount: [Int: Int] = [:]
        // Which full beams span each stem at the LEVEL-COUNTING reach.
        var beamMembers: [Int: [Int]] = [:] // beamIdx → [stem.index]
        // GROUP members per beam, at the looser inheritance reach (a
        // superset of `beamMembers`). Band-miss interior stems land here so
        // they inherit the primary level via union-find even though their
        // measured end fell outside the tight level-counting reach.
        var beamGroupMembers: [Int: [Int]] = [:]
        for (bi, beam) in fullBeams.enumerated() {
            for s in stems {
                if fullBeamSpans(beam, stem: s) {
                    fullCount[s.index, default: 0] += 1
                    beamMembers[bi, default: []].append(s.index)
                    beamGroupMembers[bi, default: []].append(s.index)
                } else if stemInBeamGroup(beam, stem: s) {
                    beamGroupMembers[bi, default: []].append(s.index)
                }
            }
        }

        // Union-find over stems joined by a shared full beam (group reach).
        var uf = UnionFind(ids: stems.map(\.index))
        for (_, members) in beamGroupMembers where members.count >= 2 {
            for k in 1 ..< members.count {
                uf.union(members[0], members[k])
            }
        }
        var groupSize: [Int: Int] = [:] // root → member count
        for s in stems {
            groupSize[uf.find(s.index), default: 0] += 1
        }

        // Stub ownership: a stub points toward the stem at one of its ends.
        // A left-pointing stub (drawn toward the left) owns the stem at its
        // RIGHT end; a right-pointing stub owns the stem at its LEFT end. We
        // detect direction by which end is nearer a stem, and credit that
        // stem with one secondary level.
        var stubCount: [Int: Int] = [:]
        for stub in stubBeams {
            guard let owner = stubOwner(stub, stems: stems) else { continue }
            stubCount[owner, default: 0] += 1
        }

        // Compose the final level per stem.
        var levels: [Int: Int] = [:]
        for s in stems {
            let cover = fullCount[s.index] ?? 0
            let inGroup = (groupSize[uf.find(s.index)] ?? 1) >= 2
            var level = cover
            // Interior inheritance: a grouped stem is at least an eighth.
            if inGroup, level < 1 { level = 1 }
            // Owned partial-beam stubs add secondary levels (only meaningful
            // when the stem is already beamed at the primary level).
            if level >= 1 { level += (stubCount[s.index] ?? 0) }
            levels[s.index] = level
        }
        return levels
    }

    /// The stem a partial-beam stub belongs to. A stub touches exactly one
    /// stem (at the end it points toward's opposite — a left-pointing stub
    /// attaches to the stem at its RIGHT edge, a right-pointing stub at its
    /// LEFT edge). We pick the stem whose x is nearest one of the stub's two
    /// x-ends AND whose beamed end falls in the stub's band there, breaking
    /// ties by proximity. Returns nil if no stem is plausibly attached.
    private static func stubOwner(
        _ stub: PathSegment, stems: [StemInfo],
    ) -> Int? {
        guard let q = stub.quad else { return nil }
        let lo = q.xRange.lowerBound
        let hi = q.xRange.upperBound
        var best: (stem: Int, dist: CGFloat)?
        for s in stems {
            // Candidate attach distance = nearest stub end to the stem x.
            let dLeft = abs(s.x - lo)
            let dRight = abs(s.x - hi)
            let d = min(dLeft, dRight)
            guard d <= beamXPad + 2 else { continue }
            // One of the stem's ends must fall within the stub band at the
            // attach x (clamped inside the quad by topY/botY).
            let bandLo = q.botY(at: s.x) - beamBandPad
            let bandHi = q.topY(at: s.x) + beamBandPad
            let topIn = s.hiY >= bandLo && s.hiY <= bandHi
            let botIn = s.loY >= bandLo && s.loY <= bandHi
            guard topIn || botIn else { continue }
            if let current = best {
                if d < current.dist { best = (s.index, d) }
            } else {
                best = (s.index, d)
            }
        }
        return best?.stem
    }
}

// MARK: - Rhythm-pass bridge

extension PDFImporter {
    /// Compute the per-stem beam level for every stem in a measure, keyed by
    /// the stem's index in `stems`. Builds `StemInfo` (x / vertical span) for
    /// each stem, then defers to `beamLevels`.
    static func computeBeamLevels(
        stems: [PathSegment], beams: [PathSegment],
    ) -> [Int: Int] {
        guard !stems.isEmpty, !beams.isEmpty else { return [:] }
        let infos: [StemInfo] = stems.enumerated().map { idx, stem in
            StemInfo(
                index: idx,
                x: stem.rect.midX,
                loY: stem.rect.minY,
                hiY: stem.rect.maxY,
            )
        }
        return beamLevels(stems: infos, beams: beams)
    }

    // MARK: - Stem attachment (notehead → stem)

    /// Penalty (pt) added when a notehead is on the wrong side of a stem.
    /// Sized to break a near-tie between an own-stem and a neighbour without
    /// overriding a clearly-closer stem.
    static let sideMismatchPenalty: CGFloat = 4.0

    /// The stem abutting a notehead at (`x`, `noteY`), with its index in
    /// `stems`. A stem sits ~4–6pt to the side of the notehead (its right
    /// edge for stem-up, left for stem-down), so candidates are verticals
    /// within ~7pt in x — under the ~10pt note-to-note spacing, so a
    /// neighbour can't be grabbed.
    ///
    /// Among the x-candidates, pick the stem minimizing a COMBINED distance
    /// (`stemCost`): x-offset + the notehead's distance from the stem's
    /// vertical span + a wrong-side penalty. A note's own stem abuts its
    /// notehead — close in x AND starting at the notehead's y, on the
    /// correct side — so the joint cost robustly resolves the correct stem
    /// when two stems share (or nearly share) an x: a second voice / octave
    /// stem at the same x is far in y; a y-coincidental neighbour from
    /// another voice is farther in x (and on the wrong side). Using x alone
    /// mis-routed a note to a y-coincidental stem in the wrong beam group
    /// (interior eighth read as a quarter); using y alone re-routed a note
    /// off its own (x-abutting) stem onto a y-overlapping neighbour
    /// (trailing note over-read as a sixteenth).
    static func nearestStem(
        toX x: CGFloat, noteY: CGFloat, stems: [PathSegment],
    ) -> (stem: PathSegment, index: Int)? {
        let candidates = stems.enumerated().filter {
            abs($0.element.rect.midX - x) <= 7
        }
        guard let best = candidates.min(by: { a, b in
            stemCost(a.element, x: x, noteY: noteY)
                < stemCost(b.element, x: x, noteY: noteY)
        }) else { return nil }
        return (best.element, best.offset)
    }

    /// Joint stem-attachment cost: x-offset from the notehead, the
    /// notehead's y-distance from the stem's vertical span, plus a SIDE
    /// penalty when the notehead sits on the geometrically wrong side of the
    /// stem. A stem extends AWAY from its notehead: a stem-up stem (span
    /// above the notehead) attaches at the notehead's RIGHT (so the notehead
    /// is to the stem's left, `x < stemX`); a stem-down stem attaches at the
    /// left. In a dense run, a note's own (correct-side) stem and a
    /// neighbour's (wrong-side) stem can be near-equal in raw x-distance; the
    /// side penalty tips the choice to the correct-side stem so a note isn't
    /// routed onto a neighbour's higher beam level (8 over-read as 16).
    static func stemCost(
        _ stem: PathSegment, x: CGFloat, noteY: CGFloat,
    ) -> CGFloat {
        let base = abs(stem.rect.midX - x) + stemYDistance(stem, noteY: noteY)
        let stemUp = stem.rect.midY > noteY
        // Correct side: stem-up ⇒ notehead left of stem (x < stemX);
        // stem-down ⇒ notehead right of stem (x > stemX).
        let onWrongSide = stemUp ? (x > stem.rect.midX) : (x < stem.rect.midX)
        return base + (onWrongSide ? sideMismatchPenalty : 0)
    }

    /// Distance from `noteY` to a stem's vertical span (0 when inside).
    static func stemYDistance(
        _ stem: PathSegment, noteY: CGFloat,
    ) -> CGFloat {
        if noteY < stem.rect.minY { return stem.rect.minY - noteY }
        if noteY > stem.rect.maxY { return noteY - stem.rect.maxY }
        return 0
    }
}
