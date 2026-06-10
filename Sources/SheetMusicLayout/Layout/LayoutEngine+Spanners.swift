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
                let fromX = startX(
                    anchor: anchor,
                    measure: system.measures[startLocal],
                    metrics: metrics,
                )
                let toX = endX(
                    anchor: anchor,
                    measure: system.measures[endLocal],
                    metrics: metrics,
                )
                let y = anchorY(
                    in: system, belowStaff: belowStaff,
                    staffIndex: anchor.startStaff,
                    measureRange: startLocal ... endLocal,
                    metrics: metrics,
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
                let fromX = startX(
                    anchor: anchor,
                    measure: startSystem.measures[startLocal],
                    metrics: metrics,
                )
                let toXStart = startSystem.size.width - metrics.sp * 2
                let yStart = anchorY(
                    in: startSystem, belowStaff: belowStaff,
                    staffIndex: anchor.startStaff,
                    measureRange: startLocal ..< startSystem.measures.count,
                    metrics: metrics,
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
                        let y = anchorY(
                            in: midSystem, belowStaff: belowStaff,
                            staffIndex: anchor.startStaff,
                            measureRange: 0 ..< midSystem.measures.count,
                            metrics: metrics,
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
                let toXEnd = endX(
                    anchor: anchor,
                    measure: endSystem.measures[endLocal],
                    metrics: metrics,
                )
                let yEnd = anchorY(
                    in: endSystem, belowStaff: belowStaff,
                    staffIndex: anchor.endStaff,
                    measureRange: 0 ... endLocal,
                    metrics: metrics,
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
            return measure.origin.x + local
        }
        return measure.origin.x + measure.width - metrics.sp * 2
    }

    static func isBelowStaff(kind: Spanner.Kind) -> Bool {
        switch kind {
        case .hairpin, .pedal: true
        default: false
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
    ) -> CGFloat where R.Bound == Int {
        anchorY(
            in: system, belowStaff: belowStaff,
            staffIndex: staffIndex, metrics: metrics,
        )
    }

    static func anchorY(
        in system: LayoutSystem,
        belowStaff: Bool,
        staffIndex: Int,
        metrics: StaffMetrics,
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
        return origin.y - metrics.sp * 4
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
        case .glissando, .other: return .textLine
        }
    }
}
