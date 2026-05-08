// swiftlint:disable function_body_length file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Anchor describing a Spanner's position before it has been resolved
    /// to absolute system-level coordinates.
    struct SpannerAnchor: Sendable, Equatable {
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

    /// Walk every staff / measure / voice and collect Spanner anchors.
    /// `endTick` carries the in-measure offset of the end anchor when
    /// the source provided `<next><fractions>` (partial-measure span);
    /// otherwise the spanner stops at the end of `endMeasure`.
    static func collectSpanners(score: Score) -> [SpannerAnchor] {
        var out: [SpannerAnchor] = []
        for (staffIdx, entry) in score.allStaves.enumerated() {
            let staff = entry.staff
            for (measureIdx, measure) in staff.measures.enumerated() {
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
                                division: score.division
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
                                voltaEndings: sp.voltaEndings
                            ))
                        }
                        switch el {
                        case let .chord(c):
                            tick += c.duration.ticks(
                                division: score.division)
                        default: break
                        }
                    }
                }
            }
        }
        return out
    }

    static func attachSpanners(
        to systems: [LayoutSystem],
        anchors: [SpannerAnchor],
        score: Score,
        metrics: StaffMetrics
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
                    measureLocation.keys.max() ?? anchor.startMeasure
                )
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
                    metrics: metrics
                )
                let toX = endX(
                    anchor: anchor,
                    measure: system.measures[endLocal],
                    metrics: metrics
                )
                let y = anchorY(
                    in: system, belowStaff: belowStaff,
                    staffIndex: anchor.startStaff,
                    measureRange: startLocal ... endLocal,
                    metrics: metrics
                )
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: y),
                    toOrigin: CGPoint(x: toX, y: y),
                    continuesLeft: false,
                    continuesRight: false,
                    text: anchor.rawType
                ))
            } else {
                let startSystem = systems[startSys]
                let fromX = startX(
                    anchor: anchor,
                    measure: startSystem.measures[startLocal],
                    metrics: metrics
                )
                let toXStart = startSystem.size.width - metrics.sp * 2
                let yStart = anchorY(
                    in: startSystem, belowStaff: belowStaff,
                    staffIndex: anchor.startStaff,
                    measureRange: startLocal ..< startSystem.measures.count,
                    metrics: metrics
                )
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: yStart),
                    toOrigin: CGPoint(x: toXStart, y: yStart),
                    continuesLeft: false,
                    continuesRight: true,
                    text: anchor.rawType
                ))
                if endSys > startSys + 1 {
                    for mid in (startSys + 1) ..< endSys {
                        let midSystem = systems[mid]
                        let y = anchorY(
                            in: midSystem, belowStaff: belowStaff,
                            staffIndex: anchor.startStaff,
                            measureRange: 0 ..< midSystem.measures.count,
                            metrics: metrics
                        )
                        extraPerSystem[mid].append(.spannerSegment(
                            kind: kind,
                            fromOrigin: CGPoint(
                                x: metrics.sp * 2, y: y
                            ),
                            toOrigin: CGPoint(
                                x: midSystem.size.width - metrics.sp * 2,
                                y: y
                            ),
                            continuesLeft: true,
                            continuesRight: true,
                            text: anchor.rawType
                        ))
                    }
                }
                let endSystem = systems[endSys]
                let fromXEnd: CGFloat = metrics.sp * 2
                let toXEnd = endX(
                    anchor: anchor,
                    measure: endSystem.measures[endLocal],
                    metrics: metrics
                )
                let yEnd = anchorY(
                    in: endSystem, belowStaff: belowStaff,
                    staffIndex: anchor.endStaff,
                    measureRange: 0 ... endLocal,
                    metrics: metrics
                )
                extraPerSystem[endSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromXEnd, y: yEnd),
                    toOrigin: CGPoint(x: toXEnd, y: yEnd),
                    continuesLeft: true,
                    continuesRight: false,
                    text: anchor.rawType
                ))
            }
        }

        return systems.enumerated().map { idx, system in
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners + extraPerSystem[idx],
                sp: system.sp
            )
        }
    }

    /// System-local X for a spanner's start edge. When the source
    /// gives us an in-measure tick (partial-measure spanners — an 8va
    /// over the last chord, a slur starting mid-measure), look the
    /// tick up in the per-measure `tickColumns` map so the line
    /// begins above the actual chord. Otherwise fall back to the
    /// measure's left edge with the historical 2-sp inset.
    static func startX(
        anchor: SpannerAnchor,
        measure: LayoutMeasure,
        metrics: StaffMetrics
    ) -> CGFloat {
        if anchor.startTick > 0,
           let local = measure.tickColumns[anchor.startTick]
        {
            return measure.origin.x + local
        }
        return measure.origin.x + metrics.sp * 2
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
        metrics: StaffMetrics
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
    /// behaviour anchored everything to the top / bottom staff of the
    /// system, which placed an 8va belonging to staff N onto the top
    /// staff of a multi-staff score.
    /// Walk voice 0 of `measure` summing chord durations to recover the
    /// measure's tick width. Mirrors what `LayoutEngine+Lyrics` does
    /// for melisma extents — there is no shared score-level helper.
    private static func measureTickCount(_ m: Measure, division: Int) -> Int {
        guard let v0 = m.voices.first else { return 0 }
        var total = 0
        for el in v0.elements {
            if case let .chord(c) = el {
                total += c.duration.ticks(division: division)
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
        division: Int
    ) -> (endMeasure: Int, endTick: Int) {
        let nMeas = max(0, nextMeasuresOffset)
        let fracTicks = nextFractionsOffset?.ticks(division: division) ?? 0

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
                let mTicks = measureTickCount(
                    measures[measureIdx], division: division
                )
                if rawTick <= mTicks { break }
                rawTick -= mTicks
                measureIdx += 1
            }
            // Snapping a tick that lands exactly on the right barline
            // to the right-edge sentinel keeps the layout's `endX`
            // path falling through to "right edge of measure" rather
            // than chasing an absent `tickColumns[mTicks]` entry.
            if measureIdx < measures.count {
                let mTicks = measureTickCount(
                    measures[measureIdx], division: division
                )
                if rawTick == mTicks { return (measureIdx, 0) }
                return (measureIdx, max(0, rawTick))
            }
            return (max(0, measures.count - 1), 0)
        }
        // Negative remainder: roll back into earlier measures.
        while measureIdx > 0, rawTick < 0 {
            measureIdx -= 1
            rawTick += measureTickCount(
                measures[measureIdx], division: division
            )
        }
        return (max(0, measureIdx), max(0, rawTick))
    }

    static func anchorY<R>(
        in system: LayoutSystem,
        belowStaff: Bool,
        staffIndex: Int,
        measureRange: R,
        metrics: StaffMetrics
    ) -> CGFloat where R: RangeExpression, R.Bound == Int {
        let origins = system.staffOrigins
        let clamped = max(0, min(staffIndex, origins.count - 1))
        let origin = origins.indices.contains(clamped)
            ? origins[clamped] : CGPoint(x: 0, y: 0)
        let staffTop = origin.y
        let staffBottom = origin.y + metrics.staffHeight
        // Default fallback band, kept for above-staff spanners and as
        // a floor when the obstacle scan finds nothing.
        let defaultBelow = staffBottom + metrics.sp * 3
        let defaultAbove = staffTop - metrics.sp * 4
        guard belowStaff else { return defaultAbove }
        // Boundary of the next staff — staying above it prevents a
        // below-staff hairpin on staff K from sliding into staff K+1's
        // ink. For the bottom staff, fall through to the system's
        // bottom edge so we never push the line off-canvas.
        let nextStaffTop: CGFloat = {
            let nextIdx = clamped + 1
            if origins.indices.contains(nextIdx) {
                return origins[nextIdx].y
            }
            return system.size.height
        }()

        // Scan obstacles in the range and use the deepest
        // (largest-Y) one. Walk system.measures slice for performance.
        let measures = system.measures
        let validRange: ClosedRange<Int>
        do {
            let upper = max(0, measures.count - 1)
            let raw = measureRange.relative(to: 0 ..< measures.count)
            let lo = max(0, min(raw.lowerBound, upper))
            let hi = max(lo, min(raw.upperBound - 1, upper))
            validRange = lo ... hi
        }

        var deepest: CGFloat = staffBottom
        for mIdx in validRange {
            guard mIdx < measures.count else { break }
            let m = measures[mIdx]
            for el in m.elements {
                guard let (yMin, yMax) = elementYExtent(el)
                else { continue }
                // Convert measure-local Y to system-local.
                let elTop = m.origin.y + yMin
                let elBottom = m.origin.y + yMax
                // Only consider obstacles below the staff bottom AND
                // above the next staff. This keeps lyrics on the
                // staff above us out of the way.
                guard elBottom > staffBottom + metrics.sp * 0.5,
                      elTop < nextStaffTop
                else { continue }
                if elBottom > deepest { deepest = elBottom }
            }
        }
        // 1.25 sp clearance below the deepest obstacle, capped at the
        // next staff's top minus a small inset so the hairpin never
        // collides with the next system staff.
        let withClearance = deepest + metrics.sp * 1.25
        let ceiling = nextStaffTop - metrics.sp * 0.5
        return min(max(defaultBelow, withClearance), ceiling)
    }

    /// Approximate Y extent (in measure-local coords) for elements
    /// that sit below the staff and could collide with a below-staff
    /// spanner. Returns nil for elements we don't care about (chord
    /// glyphs, key/time sigs, etc. — those live on/above the staff
    /// and don't push hairpins lower).
    private static func elementYExtent(
        _ el: LayoutElement
    ) -> (yMin: CGFloat, yMax: CGFloat)? {
        switch el {
        case let .textMark(.lyrics, _, origin):
            // Lyric text is rendered with `origin.y` as the baseline.
            // Cap-height ≈ 1.4 sp above, descender ≈ 0.4 sp below.
            // Caller doesn't know `metrics.sp` so we pad with absolute
            // values that work for typical staff sizes — the goal is
            // a *lower bound* on the descender, not pixel precision.
            return (origin.y - 6, origin.y + 4)
        default:
            return nil
        }
    }

    static func layoutKind(
        anchor: SpannerAnchor
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
