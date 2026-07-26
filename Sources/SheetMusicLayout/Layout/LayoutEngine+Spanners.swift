// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Anchor describing a Spanner's position before it has been resolved
    /// to absolute system-level coordinates.
    struct SpannerAnchor: Equatable {
        let kind: Spanner.Kind
        let rawType: String
        let startStaff: Int
        let startMeasure: Int
        let startTick: Int
        let endStaff: Int
        let endMeasure: Int
        /// Tick at which the spanner ends, in the END measure's local
        /// tick frame (0 = start of `endMeasure`). Computed from
        /// `nextFractionsOffset`; falls back to 0 (end-of-measure
        /// anchor) when the spanner stops at a measure boundary.
        let endTick: Int
        let voltaEndings: [Int]
        /// Vibrato subtype. Meaningful only when `kind == .vibrato`.
        let vibratoType: VibratoType?
    }

    /// Per-staff set of measure indices covered by a visible
    /// below-staff spanner (hairpin, pedal). Used by lyric placement
    /// to push the verse-0 baseline below the spanner band so a
    /// hairpin can sit between the staff and the lyric row — the
    /// MuseScore convention. Crescendo / decrescendo direction and
    /// in-measure tick offsets are irrelevant here; the question is
    /// purely "does this measure host a below-staff spanner glyph?"
    static func belowStaffSpannerCoverage(score: Score) -> [Int: Set<Int>] {
        var out: [Int: Set<Int>] = [:]
        for (staffIdx, entry) in score.allStaves.enumerated() {
            let staff = entry.staff
            var covered: Set<Int> = []
            for (measureIdx, measure) in staff.measures.enumerated() {
                for voice in measure.voices {
                    for el in voice.elements {
                        guard case let .spanner(sp) = el,
                              sp.visible,
                              isBelowStaff(kind: sp.kind)
                        else { continue }
                        let lastIdx = min(
                            staff.measures.count - 1,
                            measureIdx + max(0, sp.nextMeasuresOffset),
                        )
                        for m in measureIdx ... lastIdx {
                            covered.insert(m)
                        }
                    }
                }
            }
            if !covered.isEmpty { out[staffIdx] = covered }
        }
        return out
    }

    /// Walk every staff / measure / voice and collect Spanner anchors.
    /// `endTick` carries the in-measure offset of the end anchor when
    /// the source provided `<next><fractions>` (partial-measure span);
    /// otherwise the spanner stops at the end of `endMeasure`.
    static func collectSpanners(score: Score) -> [SpannerAnchor] {
        var out: [SpannerAnchor] = []
        for (staffIdx, entry) in score.allStaves.enumerated() {
            let staff = entry.staff
            let measureDurations = staff.measures.effectiveMeasureDurations()
            for (measureIdx, measure) in staff.measures.enumerated() {
                let measureDuration = measureIdx < measureDurations.count
                    ? measureDurations[measureIdx]
                    : Fraction(numerator: 4, denominator: 4)
                for voice in measure.voices {
                    var tick = 0
                    for el in voice.elements {
                        // Skip hidden spanners entirely — `<visible>0</visible>`
                        // on Pedal/HairPin/etc. should produce neither
                        // glyph nor reserved space at the system level.
                        // Playback / MIDI consumers read `voice.elements`
                        // directly and remain unaffected.
                        if case let .spanner(sp) = el, sp.visible {
                            // MuseScore's `<measures>N</measures>`
                            // means the spanner ends N measure
                            // boundaries forward — the end is at the
                            // START of measure (start+N), i.e. the
                            // RIGHT edge of measure (start+N-1).
                            // `<fractions>F</fractions>` shifts that
                            // anchor by F (signed) within whichever
                            // measure ultimately contains the end.
                            let (endMeasure, endTick) = endAnchor(
                                startMeasureIdx: measureIdx,
                                startTickInMeasure: tick,
                                nextMeasuresOffset: sp.nextMeasuresOffset,
                                nextFractionsOffset: sp.nextFractionsOffset,
                                measures: staff.measures,
                                division: score.division,
                            )
                            out.append(SpannerAnchor(
                                kind: sp.kind,
                                rawType: sp.rawType,
                                startStaff: staffIdx,
                                startMeasure: measureIdx,
                                startTick: tick,
                                endStaff: staffIdx,
                                endMeasure: endMeasure,
                                endTick: endTick,
                                voltaEndings: sp.voltaEndings,
                                vibratoType: sp.vibrato?.type,
                            ))
                        }
                        switch el {
                        case let .chord(c):
                            tick += c.duration
                                .resolved(in: measureDuration)
                                .ticks(division: score.division)
                        default: break
                        }
                    }
                }
            }
        }
        return out
    }

    static func attachSpanners( // swiftlint:disable:this function_body_length
        to systems: [LayoutSystem],
        anchors: [SpannerAnchor],
        score: Score,
        metrics: StaffMetrics,
    ) -> [LayoutSystem] {
        guard !anchors.isEmpty, !systems.isEmpty else { return systems }

        // Map measure-index → (systemIdx, measureIdxInSystem).
        var measureLocation: [Int: (Int, Int)] = [:]
        var globalIdx = 0
        for (sysIdx, system) in systems.enumerated() {
            for localIdx in 0 ..< system.measures.count {
                measureLocation[globalIdx] = (sysIdx, localIdx)
                globalIdx += 1
            }
        }

        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for anchor in anchors {
            guard let (startSys, startLocal) =
                measureLocation[anchor.startMeasure]
            else { continue }
            let endGlobal = max(
                anchor.startMeasure,
                min(
                    anchor.endMeasure,
                    measureLocation.keys.max() ?? anchor.startMeasure,
                ),
            )
            guard let (endSys, endLocal) = measureLocation[endGlobal]
            else { continue }

            let belowStaff = isBelowStaff(kind: anchor.kind)
            let kind = layoutKind(anchor: anchor)

            if startSys == endSys {
                let system = systems[startSys]
                let fromX = snappedHairpinStartX(
                    startX(
                        anchor: anchor,
                        measure: system.measures[startLocal],
                        metrics: metrics,
                    ),
                    anchor: anchor,
                    measure: system.measures[startLocal],
                    metrics: metrics,
                )
                let toX = snappedHairpinEndX(
                    endX(
                        anchor: anchor,
                        measure: system.measures[endLocal],
                        metrics: metrics,
                    ),
                    anchor: anchor,
                    measure: system.measures[endLocal],
                    metrics: metrics,
                    notBefore: fromX,
                )
                let y = anchorY(
                    in: system, belowStaff: belowStaff,
                    staffIndex: anchor.startStaff,
                    measureRange: startLocal ... endLocal,
                    metrics: metrics,
                    kind: kind,
                    minNorthY: vibratoMinNorthY(
                        in: system.measures,
                        localRange: startLocal ... endLocal,
                        startTick: anchor.startTick,
                        endTick: anchor.endTick,
                    ),
                )
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: y),
                    toOrigin: CGPoint(x: toX, y: y),
                    continuesLeft: false,
                    continuesRight: false,
                    text: anchor.rawType,
                ))
            } else {
                let startSystem = systems[startSys]
                let fromX = snappedHairpinStartX(
                    startX(
                        anchor: anchor,
                        measure: startSystem.measures[startLocal],
                        metrics: metrics,
                    ),
                    anchor: anchor,
                    measure: startSystem.measures[startLocal],
                    metrics: metrics,
                )
                let toXStart = startSystem.size.width - metrics.sp * 2
                let startEnd = max(startLocal, startSystem.measures.count - 1)
                let yStart = anchorY(
                    in: startSystem, belowStaff: belowStaff,
                    staffIndex: anchor.startStaff,
                    measureRange: startLocal ..< startSystem.measures.count,
                    metrics: metrics,
                    kind: kind,
                    minNorthY: vibratoMinNorthY(
                        in: startSystem.measures,
                        localRange: startLocal ... startEnd,
                        startTick: anchor.startTick,
                        endTick: 0,
                    ),
                )
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: yStart),
                    toOrigin: CGPoint(x: toXStart, y: yStart),
                    continuesLeft: false,
                    continuesRight: true,
                    text: anchor.rawType,
                ))
                if endSys > startSys + 1 {
                    for mid in (startSys + 1) ..< endSys {
                        let midSystem = systems[mid]
                        let midEnd = max(0, midSystem.measures.count - 1)
                        let y = anchorY(
                            in: midSystem, belowStaff: belowStaff,
                            staffIndex: anchor.startStaff,
                            measureRange: 0 ..< midSystem.measures.count,
                            metrics: metrics,
                            kind: kind,
                            minNorthY: vibratoMinNorthY(
                                in: midSystem.measures,
                                localRange: 0 ... midEnd,
                                startTick: 0,
                                endTick: 0,
                            ),
                        )
                        extraPerSystem[mid].append(.spannerSegment(
                            kind: kind,
                            fromOrigin: CGPoint(
                                x: metrics.sp * 2, y: y,
                            ),
                            toOrigin: CGPoint(
                                x: midSystem.size.width - metrics.sp * 2,
                                y: y,
                            ),
                            continuesLeft: true,
                            continuesRight: true,
                            text: anchor.rawType,
                        ))
                    }
                }
                let endSystem = systems[endSys]
                let fromXEnd: CGFloat = metrics.sp * 2
                let toXEnd = snappedHairpinEndX(
                    endX(
                        anchor: anchor,
                        measure: endSystem.measures[endLocal],
                        metrics: metrics,
                    ),
                    anchor: anchor,
                    measure: endSystem.measures[endLocal],
                    metrics: metrics,
                    notBefore: fromXEnd,
                )
                let yEnd = anchorY(
                    in: endSystem, belowStaff: belowStaff,
                    staffIndex: anchor.endStaff,
                    measureRange: 0 ... endLocal,
                    metrics: metrics,
                    kind: kind,
                    minNorthY: vibratoMinNorthY(
                        in: endSystem.measures,
                        localRange: 0 ... endLocal,
                        startTick: 0,
                        endTick: anchor.endTick,
                    ),
                )
                extraPerSystem[endSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromXEnd, y: yEnd),
                    toOrigin: CGPoint(x: toXEnd, y: yEnd),
                    continuesLeft: true,
                    continuesRight: false,
                    text: anchor.rawType,
                ))
            }
        }

        return systems.enumerated().map { idx, system in
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                staffAddresses: system.staffAddresses,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners + extraPerSystem[idx],
                sp: system.sp,
                invisibleSpanners: system.invisibleSpanners,
                showsInvisibleElements: system.showsInvisibleElements,
            )
        }
    }

    /// System-local X for a spanner's start edge. Look the start tick
    /// up in the per-measure `tickColumns` map so the line begins above
    /// the actual chord — this covers both partial-measure spanners (an
    /// 8va over the last chord, a slur starting mid-measure) AND the
    /// downbeat case (`startTick == 0`). The downbeat lookup matters
    /// when the measure opens with a clef / key / time signature: the
    /// first chord sits well to the right of the bar line (its column
    /// already bakes in the header indent via `contentStartX`), so a
    /// flat `origin.x + 2 sp` would start a hairpin under the clef.
    /// The 2-sp inset survives as a left floor for measures whose first
    /// chord sits very close to the bar line (no header) and as the
    /// fallback when the start tick has no recorded column.
    ///
    /// Cross-system continuation edges do NOT come through here — they
    /// use the system margin directly in `attachSpanners` — so widening
    /// this lookup can't disturb a continued line's left end.
    static func startX(
        anchor: SpannerAnchor,
        measure: LayoutMeasure,
        metrics: StaffMetrics,
    ) -> CGFloat {
        let inset = measure.origin.x + metrics.sp * 2
        if let local = measure.tickColumns[anchor.startTick] {
            return max(measure.origin.x + local, inset)
        }
        return inset
    }

    /// System-local X for a spanner's right edge. When `endTick`
    /// lands on a chord recorded in `tickColumns`, end the line at
    /// that chord's X (i.e. the start of the chord *after* the last
    /// covered one — typical MuseScore semantics). When the offset
    /// reaches the end of the measure (no chord at that tick) or the
    /// spanner has no fractional offset, fall back to the measure's
    /// right edge with the historical 2-sp inset.
    static func endX(
        anchor: SpannerAnchor,
        measure: LayoutMeasure,
        metrics: StaffMetrics,
    ) -> CGFloat {
        if anchor.endTick > 0,
           let local = measure.tickColumns[anchor.endTick]
        {
            let baseX = measure.origin.x + local
            // Mirror MuseScore trill.cpp:333: a vibrato ends 1 sp before its
            // end note so adjacent partial-measure vibratos keep a 1 sp gap
            // (otherwise consecutive vibratos touch / visually overlap).
            return anchor.kind == .vibrato ? baseX - metrics.sp : baseX
        }
        return measure.origin.x + measure.width - metrics.sp * 2
    }

    /// `Sid::autoplaceHairpinDynamicsDistance` = 0.5 sp — the clearance
    /// MuseScore keeps between a hairpin and the dynamic snapped to it.
    static let hairpinDynamicsDistanceSp: CGFloat = 0.5

    /// Push a hairpin's left edge clear of the dynamic anchored at the
    /// hairpin's own start tick. Mirrors the "make space before" half of
    /// `TLayout::manageHairpinSnapping` (`rendering/score/tlayout.cpp`):
    /// the segment starts at `dynamic.bbox.right + 0.5 sp` and loses the
    /// same amount of length.
    ///
    /// This is the ONLY thing that keeps the wedge off the glyph.
    /// Vertical autoplace deliberately leaves the pair alone —
    /// `AutoplaceRules.shouldIgnoreEachOther` exempts
    /// `dynamics × hairpin` because MuseScore snaps them into one chain
    /// that shares a band, and pushing the dynamic down would only move
    /// it further INTO the wedge (hairpins are `.wholeStaff` and never
    /// move).
    ///
    /// Only MuseScore's SHRINK halves are ported. It additionally
    /// EXTENDS a hairpin that stops more than 3 sp short of its end
    /// dynamic; that lengthens lines which do not collide today, so it
    /// is left out of a collision fix.
    static func snappedHairpinStartX(
        _ x: CGFloat,
        anchor: SpannerAnchor,
        measure: LayoutMeasure,
        metrics: StaffMetrics,
    ) -> CGFloat {
        guard anchor.kind == .hairpin,
              let extent = dynamicExtent(
                  in: measure,
                  staffIndex: anchor.startStaff,
                  tick: anchor.startTick,
              )
        else { return x }
        return max(
            x,
            measure.origin.x + extent.maxX
                + metrics.sp * hairpinDynamicsDistanceSp,
        )
    }

    /// Pull a hairpin's right edge clear of the dynamic anchored at the
    /// hairpin's own end tick — the "make space after" half of
    /// `TLayout::manageHairpinSnapping`. `notBefore` is the segment's
    /// own left edge, so a measure crowded enough that both trims cross
    /// degenerates to a zero-length line rather than a reversed one.
    ///
    /// `endTick == 0` is `endAnchor`'s right-edge sentinel: the hairpin
    /// stops at the bar line, so the dynamic that ends it sits at the
    /// downbeat of the NEXT measure and is already to the right of the
    /// line. Nothing to trim.
    static func snappedHairpinEndX(
        _ x: CGFloat,
        anchor: SpannerAnchor,
        measure: LayoutMeasure,
        metrics: StaffMetrics,
        notBefore: CGFloat,
    ) -> CGFloat {
        guard anchor.kind == .hairpin, anchor.endTick > 0,
              let extent = dynamicExtent(
                  in: measure,
                  staffIndex: anchor.endStaff,
                  tick: anchor.endTick,
              )
        else { return x }
        let trimmed = measure.origin.x + extent.minX
            - metrics.sp * hairpinDynamicsDistanceSp
        return max(min(x, trimmed), notBefore)
    }

    /// Union of the measure-local ink spans of every dynamic this
    /// staff places at `tick`, or nil when there is none. A tick can
    /// carry more than one (e.g. `p` in voice 1 and `f` in voice 2);
    /// the hairpin has to clear all of them.
    private static func dynamicExtent(
        in measure: LayoutMeasure, staffIndex: Int, tick: Int,
    ) -> (minX: CGFloat, maxX: CGFloat)? {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        for extent in measure.dynamicExtents
            where extent.staffIndex == staffIndex && extent.tick == tick
        {
            minX = min(minX, extent.minX)
            maxX = max(maxX, extent.maxX)
        }
        return minX <= maxX ? (minX, maxX) : nil
    }

    static func isBelowStaff(kind: Spanner.Kind) -> Bool {
        switch kind {
        case .hairpin, .pedal: true
        case .volta, .slur, .ottava, .textLine, .glissando, .vibrato, .other: false
        }
    }

    /// Y baseline for a spanner segment. Above-staff spanners (slur,
    /// volta, ottava, …) sit a few sp above the spanner's *own staff*;
    /// below-staff spanners (hairpin, pedal) sit below it. The legacy
    /// behavior anchored everything to the top / bottom staff of the
    /// system, which placed an 8va belonging to staff N onto the top
    /// staff of a multi-staff score.
    /// Walk voice 0 of `measure` summing chord durations to recover the
    /// measure's tick width. `measureDuration` is used to resolve any
    /// `.measure` rest — pass the effective duration for this measure.
    private static func measureTickCount(
        _ m: Measure,
        division: Int,
        measureDuration: Fraction,
    ) -> Int {
        guard let v0 = m.voices.first else { return 0 }
        var total = 0
        for el in v0.elements {
            if case let .chord(c) = el {
                total += c.duration.resolved(in: measureDuration).ticks(division: division)
            }
        }
        return total
    }

    /// Resolve a Spanner's end anchor (measure index + in-measure tick)
    /// from its `<measures>` / `<fractions>` offsets. MuseScore's
    /// `<next>` location is **relative to the begin spanner's tick** —
    /// `<measures>N</measures>` advances N measure boundaries forward
    /// from there, then `<fractions>F</fractions>` adds (or, when
    /// negative, subtracts) F worth of ticks. We resolve the result
    /// to a (measureIndex, in-measure tick) pair, with `endTick = 0`
    /// signalling an end-of-previous-measure (right-edge) anchor.
    static func endAnchor(
        startMeasureIdx: Int,
        startTickInMeasure: Int,
        nextMeasuresOffset: Int,
        nextFractionsOffset: Fraction?,
        measures: [Measure],
        division: Int,
    ) -> (endMeasure: Int, endTick: Int) {
        let nMeas = max(0, nextMeasuresOffset)
        let fracTicks = nextFractionsOffset?.ticks(division: division) ?? 0
        let measureDurations = measures.effectiveMeasureDurations()

        if fracTicks == 0 {
            if nMeas > 0 {
                return (startMeasureIdx + nMeas - 1, 0) // right-edge sentinel
            }
            return (startMeasureIdx, 0)
        }
        // The fractional offset is added to the begin spanner's
        // in-measure tick, then we walk through measure boundaries
        // until the running tick falls inside one. This handles a
        // partial-measure spanner that crosses the bar (5/8 + 3/8 →
        // end of current measure) without misplacing it onto the
        // next measure's interior.
        var measureIdx = startMeasureIdx + nMeas
        var rawTick = startTickInMeasure + fracTicks
        if rawTick >= 0 {
            while measureIdx < measures.count {
                let mDuration = measureIdx < measureDurations.count
                    ? measureDurations[measureIdx]
                    : Fraction(numerator: 4, denominator: 4)
                let mTicks = measureTickCount(
                    measures[measureIdx], division: division,
                    measureDuration: mDuration,
                )
                if rawTick <= mTicks { break }
                rawTick -= mTicks
                measureIdx += 1
            }
            // Snapping a tick that lands exactly on a barline back
            // to the right-edge sentinel of the *previous* measure
            // keeps `attachSpanners.endX` from drawing one extra
            // measure: a hairpin written as `<measures>2</measures>
            // <fractions>-1/8</fractions>` (= "ends 1/8 before the
            // start of (start+2)") resolves here to (start+1, 1680);
            // a hairpin with `<measures>1</measures>` (= "ends at
            // the start of (start+1)") resolves to the start measure
            // with the right-edge sentinel.
            if measureIdx < measures.count {
                let mDuration = measureIdx < measureDurations.count
                    ? measureDurations[measureIdx]
                    : Fraction(numerator: 4, denominator: 4)
                let mTicks = measureTickCount(
                    measures[measureIdx], division: division,
                    measureDuration: mDuration,
                )
                if rawTick == mTicks { return (measureIdx, 0) }
                if rawTick == 0, measureIdx > startMeasureIdx {
                    return (measureIdx - 1, 0)
                }
                return (measureIdx, max(0, rawTick))
            }
            return (max(0, measures.count - 1), 0)
        }
        // Negative remainder: roll back into earlier measures.
        while measureIdx > 0, rawTick < 0 {
            measureIdx -= 1
            let mDuration = measureIdx < measureDurations.count
                ? measureDurations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
            rawTick += measureTickCount(
                measures[measureIdx], division: division,
                measureDuration: mDuration,
            )
        }
        if rawTick == 0, measureIdx > startMeasureIdx {
            return (measureIdx - 1, 0)
        }
        return (max(0, measureIdx), max(0, rawTick))
    }

    static func anchorY<R: RangeExpression>(
        in system: LayoutSystem,
        belowStaff: Bool,
        staffIndex: Int,
        measureRange _: R,
        metrics: StaffMetrics,
        kind: LayoutElement.SpannerKind? = nil,
        minNorthY: CGFloat? = nil,
    ) -> CGFloat where R.Bound == Int {
        anchorY(
            in: system, belowStaff: belowStaff,
            staffIndex: staffIndex, metrics: metrics, kind: kind,
            minNorthY: minNorthY,
        )
    }

    static func anchorY(
        in system: LayoutSystem,
        belowStaff: Bool,
        staffIndex: Int,
        metrics: StaffMetrics,
        kind: LayoutElement.SpannerKind? = nil,
        minNorthY: CGFloat? = nil,
    ) -> CGFloat {
        let origins = system.staffOrigins
        let clamped = max(0, min(staffIndex, origins.count - 1))
        let origin = origins.indices.contains(clamped)
            ? origins[clamped] : CGPoint(x: 0, y: 0)
        if belowStaff {
            // MuseScore convention: hairpin sits in the band just below
            // the staff, between staff bottom and any lyric row. Lyric
            // placement (`voiceMaxLyricCenterY`) is hairpin-aware and
            // pushes itself further down when a hairpin covers the
            // measure, so we keep the spanner Y at a stable offset.
            return origin.y + metrics.staffHeight + metrics.sp * 3
        }
        // Vibrato: MuseScore `vibratoPosAbove` default is −1 sp, so the
        // line sits much closer to the staff top than ottava/textLine.
        // Use 1.5 sp clearance (1 sp default + 0.5 sp breathing room).
        // When a chord's north skyline sits above this default, push the
        // vibrato up so it clears the highest notehead top.
        //
        // `minNorthY` is now the note TOP-EDGE (center − 0.5 sp, see
        // `buildChordNorthByTick`). The vibrato glyph is drawn centred
        // on `anchorY` (baseline = anchorY for Bravura's symmetric
        // ascent/descent), so its INK extends `glyphHalfHeight` below
        // `anchorY`. Clearance rule:
        //   anchorY + glyphHalfHeight + minDistance ≤ noteTopEdge
        //   anchorY ≤ noteTopEdge − minDistance − glyphHalfHeight
        //           = minNorthY   − 1.0 sp      − glyphHalfHeight
        //
        // `glyphHalfHeight` is taken from the actual Bravura glyph bbox
        // (queried via FontMetrics); for wiggleSawtoothWide the ink
        // extends ≈ 1.06 sp above and below the baseline. Falls back to
        // 0.5 sp on the Stub provider (Android / tests without CoreText).
        // This matches MuseScore's skyline + `vibratoMinDistance = 1 sp`
        // behaviour (autoplace.cpp, `autoplaceSpannerSegment`).
        if case let .vibrato(vibratoType) = kind {
            let defaultY = origin.y - metrics.sp * 1.5
            guard let minNorthY else { return defaultY }
            let halfH = vibratoGlyphHalfHeight(type: vibratoType, sp: metrics.sp)
            let clearanceY = minNorthY - metrics.sp * 1.0 - halfH
            return min(defaultY, clearanceY)
        }
        return origin.y - metrics.sp * 4
    }

    /// Minimum (highest) notehead Y across all chords in the given
    /// local measure range, for vibrato autoplace. Returns nil when
    /// there are no chords in the range (vibrato stays at default Y).
    private static func vibratoMinNorthY(
        in measures: [LayoutMeasure],
        localRange: ClosedRange<Int>,
        startTick: Int,
        endTick: Int,
    ) -> CGFloat? {
        var minY: CGFloat?
        for localIdx in localRange {
            guard localIdx < measures.count else { break }
            let m = measures[localIdx]
            for (tick, northY) in m.chordNorthByTick {
                // Start measure: only ticks at or after the spanner start
                if localIdx == localRange.lowerBound, tick < startTick { continue }
                // End measure: only ticks before endTick (0 = end-of-measure)
                if localIdx == localRange.upperBound, endTick > 0, tick >= endTick { continue }
                minY = min(minY ?? .greatestFiniteMagnitude, northY)
            }
        }
        return minY
    }

    /// Half-height of a vibrato glyph's ink extent at `sp`, measured from
    /// the baseline. The glyph is anchored at its baseline (Bravura has
    /// symmetric ascent/descent so the typographic centre = baseline), so
    /// the ink extends `halfHeight` both above and below `anchorY`. The
    /// BOTTOM edge that must clear the note top is `anchorY + halfHeight`.
    ///
    /// Uses the real Bravura glyph bbox when CoreText is available;
    /// falls back to 0.5 sp on the Stub provider (Android / unit tests
    /// without a real font).
    private static func vibratoGlyphHalfHeight(
        type: VibratoType, sp: CGFloat,
    ) -> CGFloat {
        let codepoint = SpannerGeometry.vibratoCodepoint(type: type)
        guard let cp16 = UInt16(exactly: codepoint) else { return sp * 0.5 }
        let font = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: sp * 4,
        )
        if let bbox = FontMetrics.provider.glyphPathBoundingBox(
            font: font, codepoint: cp16,
        ) {
            return bbox.height / 2
        }
        return sp * 0.5
    }

    static func layoutKind(
        anchor: SpannerAnchor,
    ) -> LayoutElement.SpannerKind {
        switch anchor.kind {
        case .slur: return .slur
        case .volta: return .volta(endings: anchor.voltaEndings)
        case .hairpin:
            let raw = anchor.rawType.lowercased()
            if raw.contains("decr") || raw.contains("dim") {
                return .hairpinClose
            }
            return .hairpinOpen
        case .pedal: return .pedal
        case .ottava: return .ottava(raw: anchor.rawType)
        case .textLine: return .textLine
        case .vibrato: return .vibrato(anchor.vibratoType ?? .guitarVibrato)
        case .glissando, .other: return .textLine
        }
    }
}
