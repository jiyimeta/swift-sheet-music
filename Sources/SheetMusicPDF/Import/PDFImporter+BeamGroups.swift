#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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
    // MARK: - Point-in-band membership (②)
    // (Quad fitting ① lives in PDFImporter+BeamQuad.swift.)

    /// Slop (pt) on a quad's x-range when testing a stem's x against it
    /// (used by partial-stub ownership). Horizontal (note-spacing) tolerance,
    /// kept absolute — NOT part of the cross-staff Y leak.
    static let beamXPad: CGFloat = 3.0

    /// Tight endpoint pad (pt) for full-beam membership. A beam's x-range
    /// endpoints coincide with its OUTERMOST group stems, so a real member
    /// sits within ~1pt of the span; the very next note (a different chord)
    /// is ~one notehead-gap (≈ 3pt+) beyond. A small pad therefore includes
    /// the outer group stems without absorbing the trailing note — the cause
    /// of a quarter after a 16th run being over-read as a sixteenth.
    static let beamEndpointPad: CGFloat = 1.5

    /// Interior margin (pt) a stem must sit inside a full beam's x-range to
    /// count as an interior group member (so an endpoint stem at the very
    /// edge — possibly the start of a *different* group — is not absorbed).
    static let beamGroupInteriorMargin: CGFloat = 2.0

    /// The three VERTICAL beam reaches, expressed in points but derived from
    /// the staff's spatium (Fix C): a small drum staff (spatium ~3.3pt) and a
    /// full vocal staff (spatium ~5pt) need proportional — not absolute —
    /// windows, else a fixed 15/24/4pt reach on a small staff crosses into a
    /// vertically-adjacent staff (the カゲロウ / 群青 neighbour-beam leak).
    ///   * `full`    — full-beam level-counting reach (was 15pt).
    ///   * `group`   — looser interior-inheritance reach (was 24pt).
    ///   * `bandPad` — stub-band half-thickness (was 4pt).
    ///
    /// The spatium multipliers were fitted on the 6-score corpus: a note's own
    /// level-determining beams attach within ≤1 spatium of its beamed end,
    /// while the nearest neighbour-staff leak sits ≥2.55 spatia away (群青;
    /// カゲロウ ≥3.5). A window in the empty 1–2sp gap separates them cleanly —
    /// verified BYTE-IDENTICAL on the leak-free scores (ギブス / ロビンソン)
    /// across the whole 1.7–2.5sp plateau, so `full`=2sp keeps a full spatium
    /// of margin above own beams while staying below the tightest leak.
    struct BeamReach {
        var full: CGFloat
        var group: CGFloat
        var bandPad: CGFloat

        /// Level-counting reach, in spatia (was 15pt ≈ 3–4.5sp — too wide on a
        /// small drum staff, where it crossed into the neighbour).
        static let fullSpatia: CGFloat = 2.0
        /// Interior-inheritance reach, in spatia (was 24pt). Kept just under
        /// the 群青 leak so a leaked beam can't grant a drum stem a group level.
        static let groupSpatia: CGFloat = 2.5
        /// Stub-band half-thickness, in spatia (was 4pt).
        static let bandSpatia: CGFloat = 1.2

        static func forSpatium(_ spatium: CGFloat) -> BeamReach {
            let sp = spatium > 0 ? spatium : 4
            return BeamReach(
                full: fullSpatia * sp,
                group: groupSpatia * sp,
                bandPad: bandSpatia * sp,
            )
        }
    }

    /// Whether a FULL `beam` horizontally spans `stem`'s x AND lies within
    /// `reach.full` of one of the stem's ends — the membership criterion used
    /// both for group union-find and for counting stacked beam levels. The
    /// x-test uses the tight `beamEndpointPad` so a note just before / after
    /// a group is not pulled in.
    static func fullBeamSpans(
        _ beam: PathSegment, stem s: StemInfo, reach: BeamReach,
    ) -> Bool {
        guard let q = beam.quad else {
            return s.x >= beam.rect.minX - beamEndpointPad
                && s.x <= beam.rect.maxX + beamEndpointPad
                && s.beamEndDistance(to: beam.rect.midY) <= reach.full
        }
        guard s.x >= q.xRange.lowerBound - beamEndpointPad,
              s.x <= q.xRange.upperBound + beamEndpointPad
        else { return false }
        let edgeMid = (q.topY(at: s.x) + q.botY(at: s.x)) / 2
        return s.beamEndDistance(to: edgeMid) <= reach.full
    }

    /// Whether `stem` is an INTERIOR member of a full `beam`'s group: its x
    /// sits strictly inside the beam's horizontal span and one of its ends
    /// is within `reach.group` of the beam edge. Used to union band-miss
    /// stems into the group so interior inheritance can floor them at the
    /// primary (eighth) level.
    static func stemInBeamGroup(
        _ beam: PathSegment, stem s: StemInfo, reach: BeamReach,
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
        return s.beamEndDistance(to: edgeMid) <= reach.group
    }

    // MARK: - Beam groups + per-stem level (③)

    /// One stem to feed the beam-group solver: its index in the measure's
    /// `stems` array, its x, its vertical span, and `beamedEndY` — the bare
    /// end where beams attach (opposite the notehead). Level counting measures
    /// a beam's distance to THIS end only, so a neighbour-staff beam grazing
    /// the notehead end isn't miscounted (the 8→16 over-read on tightly-spaced
    /// systems). `nil` ⇒ unknown; fall back to the nearer-of-both-ends test.
    struct StemInfo {
        var index: Int
        var x: CGFloat
        var loY: CGFloat
        var hiY: CGFloat
        var beamedEndY: CGFloat?

        /// Distance from `y` (a beam edge) to the stem's beam-attaching end.
        func beamEndDistance(to y: CGFloat) -> CGFloat {
            if let beamedEndY { return abs(beamedEndY - y) }
            return min(abs(hiY - y), abs(loY - y))
        }
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
        stems: [StemInfo], beams: [PathSegment], spatium: CGFloat,
    ) -> [Int: Int] {
        let reach = BeamReach.forSpatium(spatium)
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
            let spanned = stems.count(where: { fullBeamSpans(b, stem: $0, reach: reach) })
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
                if fullBeamSpans(beam, stem: s, reach: reach) {
                    fullCount[s.index, default: 0] += 1
                    beamMembers[bi, default: []].append(s.index)
                    beamGroupMembers[bi, default: []].append(s.index)
                } else if stemInBeamGroup(beam, stem: s, reach: reach) {
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
            guard let owner = stubOwner(stub, stems: stems, reach: reach)
            else { continue }
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
        _ stub: PathSegment, stems: [StemInfo], reach: BeamReach,
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
            let bandLo = q.botY(at: s.x) - reach.bandPad
            let bandHi = q.topY(at: s.x) + reach.bandPad
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
    /// the stem's index in `stems`, deferring to `beamLevels`. `noteheadOrigins`
    /// fixes each stem's beam-attaching end (the bare end, far from the abutting
    /// notehead) so a neighbour-staff beam grazing the notehead end isn't
    /// miscounted (the 8→16 over-read on tightly-spaced systems).
    static func computeBeamLevels(
        stems: [PathSegment], beams: [PathSegment],
        noteheadOrigins: [CGPoint] = [], spatium: CGFloat,
    ) -> [Int: Int] {
        guard !stems.isEmpty, !beams.isEmpty else { return [:] }
        let infos: [StemInfo] = stems.enumerated().map { idx, stem in
            StemInfo(
                index: idx,
                x: stem.rect.midX,
                loY: stem.rect.minY,
                hiY: stem.rect.maxY,
                beamedEndY: beamedEnd(
                    loY: stem.rect.minY, hiY: stem.rect.maxY,
                    stemX: stem.rect.midX, noteheads: noteheadOrigins,
                    spatium: spatium,
                ),
            )
        }
        return beamLevels(stems: infos, beams: beams, spatium: spatium)
    }

    /// The stem end where beams attach: the end farther from the notehead the
    /// stem abuts (within `stemAttachWindow` in x, y nearest either stem
    /// end). `nil` when no notehead abuts the stem.
    private static func beamedEnd(
        loY: CGFloat, hiY: CGFloat, stemX: CGFloat, noteheads: [CGPoint],
        spatium: CGFloat,
    ) -> CGFloat? {
        var bestY: CGFloat?
        var bestDist = CGFloat.greatestFiniteMagnitude
        let window = stemAttachWindow(spatium: spatium)
        for nh in noteheads where abs(nh.x - stemX) <= window {
            let d = min(abs(nh.y - loY), abs(nh.y - hiY))
            if d < bestDist { bestDist = d; bestY = nh.y }
        }
        guard let noteY = bestY else { return nil }
        return abs(hiY - noteY) >= abs(loY - noteY) ? hiY : loY
    }
}
