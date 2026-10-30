// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    // MARK: - System packing

    /// Fixed width of a multi-measure-rest collapsed bar. v1 uses a
    /// constant `~6 * sp` regardless of `count`; the count above the
    /// bar conveys magnitude, and a `log(N)` taper can be layered on
    /// later behind the same field without API churn.
    static func collapsedRunWidth(staffSpace sp: CGFloat) -> CGFloat {
        sp * 6
    }

    static func packSystems( // swiftlint:disable:this function_body_length
        context: RenderContext,
    ) -> [LayoutSystem] {
        let allStaves = context.score.allStaves
        let staves = allStaves.map(\.staff)
        let stavesCount = staves.count
        guard stavesCount > 0,
              let firstStaff = staves.first,
              !firstStaff.measures.isEmpty
        else {
            return []
        }

        let measureCount = firstStaff.measures.count
        // Stash the prior cache entries before rebuilding. Each
        // measure that hits the cache is copied forward (carrying its
        // placement results, populated later in buildSystem). Misses
        // produce a fresh entry with empty `placements`.
        let priorEntries = context.cache?.entries ?? [:]
        let priorSystemEntries = context.cache?.systemEntries ?? [:]
        context.cache?.entries = [:]
        context.cache?.systemEntries = [:]
        context.cache?.widthHits = 0
        context.cache?.widthMisses = 0
        context.cache?.placementHits = 0
        context.cache?.placementMisses = 0
        context.cache?.systemHits = 0
        context.cache?.systemMisses = 0
        context.cache?.tickAggregateHits = 0
        let sp = context.metrics.sp
        let division = context.score.division
        // Per-measure minimum width via the same cross-staff
        // tick-aggregation `tickColumns` will use, so the spacing
        // pass and the placement pass agree on segment widths.
        // (Per-staff `minimumMeasureWidth` undercounts when other
        // staves subdivide a long element — see
        // `crossStaffMinimumMeasureWidth`.)
        let plan = context.multiMeasureRestPlan
        // HBox room before a measure (`LayoutEngine+HorizontalGaps`): counted wherever a system's width is tested.
        let horizontalGaps = context.horizontalGaps
        // Read from the context, not recomputed here: it is built once
        // at layout entry (see `LayoutEngine.layout`), not once per
        // system-pack call.
        let measureDurations = context.measureDurations
        func collapsedOverride(for i: Int, baseline: CGFloat) -> CGFloat {
            if plan.runLength(startingAt: i) != nil {
                return collapsedRunWidth(staffSpace: sp)
            }
            if plan.isInteriorOfRun(i) {
                return 0
            }
            return baseline
        }
        // The collapsed-run override is a PROJECTION of the cached width,
        // never the cached width itself. `Entry.minWidth` means "this
        // measure's natural width"; the override means "what it is drawn at
        // under the CURRENT multi-measure-rest plan", which is an output.
        // Storing the output and then feeding it back in as the next call's
        // baseline destroys the natural width for good: the plan is
        // deliberately not part of the entry's predicate, so a measure that
        // has once been a run interior would keep width 0 on every later hit
        // — including after the run splits or the policy is switched off.
        // So the entry always stores the PRE-override width, and the override
        // is applied only to the value this closure RETURNS.
        //
        // Each measure's aggregate is kept alongside (the cache is optional,
        // so it cannot be the only holder): its gaps are what stretches — see
        // `naturalWidth`.
        var aggregates = [TickAggregate?](repeating: nil, count: measureCount)
        let cachedMinWidths: [CGFloat] = (0 ..< measureCount).map { i in
            let inputs = WidthInputs(
                measureIdx: i, staves: staves, measureDuration: measureDuration(measureDurations, at: i),
                metrics: context.metrics, division: division, options: context.options,
                chordSymbolCase: context.score.style.chordSymbolCase,
            )
            if let prior = priorEntries[i], prior.matches(inputs) {
                // Cache hit: copy the prior entry forward verbatim. Its
                // `minWidth` is the natural width, so it stays valid under
                // any plan — only the returned value is overridden.
                context.cache?.entries[i] = prior
                context.cache?.widthHits += 1
                aggregates[i] = prior.tickAggregate
                return collapsedOverride(for: i, baseline: prior.minWidth)
            }
            // The natural-width walk a horizontal host runs just before this
            // (`naturalContentWidth(score:options:cache:)`) may have computed
            // this measure from the very same inputs — it reads the score
            // before accidentals are suppressed, which leaves most measures
            // as they are. Its width and aggregate are then this measure's;
            // only the placements, which that walk never builds, start empty.
            if let natural = context.cache?.naturalWidthEntries[i], natural.matches(inputs) {
                context.cache?.entries[i] = natural
                context.cache?.widthHits += 1
                aggregates[i] = natural.tickAggregate
                return collapsedOverride(for: i, baseline: natural.minWidth)
            }
            context.cache?.widthMisses += 1
            let entry = widthEntry(measureIdx: i, inputs: inputs, staves: staves, metrics: context.metrics)
            context.cache?.entries[i] = entry
            aggregates[i] = entry.tickAggregate
            return collapsedOverride(for: i, baseline: entry.minWidth)
        }

        // Cancellation naturals widen a measure that the per-measure
        // width cache cannot see them in — the naturals come from the
        // PRECEDING key, which is deliberately not part of that cache's
        // predicate. Add their advance outside the cache, exactly as
        // `synthHeaderOverhead` is added outside it for a system head.
        // Collapsed multi-measure-rest bars keep their override width
        // (a run never contains a key change).
        let cancellationWidths = cancellationNaturalWidths(
            staves: staves, metrics: context.metrics,
        )
        /// Likewise the clef column a measure's cached width left out because
        /// the measure before draws its opening clef — when the plan collapses
        /// that measure into a multi-measure rest, which draws nothing, the
        /// clef goes back into this measure's own header
        /// (`leadingClefDrawnBefore`).
        func restoredClefColumn(_ i: Int) -> CGFloat {
            guard leadingClefDrawnBefore(measureIdx: i, staves: staves, plan: nil),
                  !leadingClefDrawnBefore(measureIdx: i, staves: staves, plan: plan),
                  staves.contains(where: { followingClef(after: i - 1, in: $0) != nil })
            else { return 0 }
            return sp * 2
        }
        let minWidths: [CGFloat] = cachedMinWidths.indices.map { i in
            guard plan.runLength(startingAt: i) == nil,
                  !plan.isInteriorOfRun(i)
            else { return cachedMinWidths[i] }
            let cancellation = i < cancellationWidths.count ? cancellationWidths[i] : 0
            return cachedMinWidths[i] + cancellation + restoredClefColumn(i)
        }

        // Each measure's aggregate as it is spaced when the next measure
        // follows it on the same line, where the syllables either side of
        // the barline must keep clear of each other (`LayoutEngine+LyricJoin`),
        // and what that adds to its minimum width. Kept out of the cached
        // width, which is the measure's alone: a system pays it for every
        // measure but its last.
        let joinedAggregates = lyricJoinedAggregates(aggregates, staves: staves, metrics: context.metrics)
        let joinGrowths: [CGFloat] = aggregates.indices.map { i in
            guard let joined = joinedAggregates[i], let alone = aggregates[i] else { return 0 }
            return max(sp * 4, joined.minimumContentWidth) - max(sp * 4, alone.minimumContentWidth)
        }

        // A measure's natural width: `width`, its minimum, with only its gaps
        // at the host's stretch — what `justifiedWidths` gives it on a line
        // justified to exactly that stretch. The header, the room around the
        // content and anything else outside the gaps count once, as MuseScore
        // counts a line's natural width (`computeSpacingForFullSystem`), and a
        // floor adds only what stretching the weights has not already cleared.
        // A collapsed multi-measure rest, or a bar with nothing timed in it,
        // has no gaps and scales as a whole. `joined`: as spaced with a
        // measure after it on the line.
        let naturalStretch = context.options.spacing.systemStretch
        func naturalWidth(_ i: Int, _ width: CGFloat, joined: Bool = false) -> CGFloat {
            guard let agg = (joined ? joinedAggregates[i] : nil) ?? aggregates[i],
                  plan.runLength(startingAt: i) == nil,
                  !plan.isInteriorOfRun(i),
                  agg.totalWeight > 0
            else { return width * naturalStretch }
            let minimum = max(sp * 4, agg.minimumContentWidth)
            let content = max(sp * 4, agg.contentWidth(atStretch: naturalStretch))
            return width + max(0, content - minimum - sp)
        }
        /// What measure `i` adds to the line's natural width once a measure
        /// follows it on the line: its join growth, at the natural stretch.
        func naturalJoinGrowth(_ i: Int) -> CGFloat {
            guard joinedAggregates[i] != nil else { return 0 }
            return naturalWidth(i, joinGrowths[i], joined: true) - naturalWidth(i, 0)
        }

        // What each possible system boundary would announce at its
        // trailing edge, and how much room that takes. Indexed by the
        // measure a system would END at, so the entry a break consults is
        // driven by the measure that would OPEN the next system.
        let courtesies = trailingCourtesies(
            staves: staves, metrics: context.metrics,
        )

        // Clef state persists ACROSS systems: engraving convention
        // redraws the currently active clef at the start of every
        // new system (line break).  Without this persistence,
        // continuation systems would either omit the clef or restore
        // an outdated default, losing any mid-piece clef changes.
        var activeClefs: [NotatedClef] = defaultClefRawTypes(
            addresses: allStaves,
        ).map { NotatedClef(rawType: $0) }

        // Key signatures follow the same engraving rule: redraw the
        // currently active key at the start of every system.  Core
        // storage is `concertKey` — positive = sharps, negative =
        // flats, 0 = C major (drawn as nothing).
        var activeKeys: [Int] = Array(
            repeating: 0,
            count: stavesCount,
        )

        var systems: [LayoutSystem] = []
        var currentY: CGFloat = 0
        var cursor = 0
        var isFirstSystem = true
        // Dynamic label width — measure the actual longest part
        // label so the first system doesn't reserve more indent
        // than the longest text needs. MuseScore's
        // `Sid::firstSystemIndent` adds zero base indent and
        // sizes the bracket region purely from the longest
        // instrument name; previously we hard-coded 80 pt, which
        // pushed the first system noticeably right of the page's
        // content margin even for short labels like "Lead" /
        // "Top".
        // Same gutter inputs as `buildSystem` consumes — keeping the
        // wrap estimate aligned with the actual indent so measures
        // don't overflow when a tall brace widens the gutter.
        let gutterInfo = bracketGutterInfo(score: context.score)
        let firstSystemLabelW = labelWidth(
            score: context.score,
            metrics: context.metrics,
            useLong: true,
            bracketColumnCount: gutterInfo.columnCount,
            maxBraceStaffCount: gutterInfo.maxBraceStaffCount,
        )
        let continuationLabelW = labelWidth(
            score: context.score,
            metrics: context.metrics,
            useLong: false,
            bracketColumnCount: gutterInfo.columnCount,
            maxBraceStaffCount: gutterInfo.maxBraceStaffCount,
        )
        while cursor < measureCount {
            // Part-label width depends on whether this is the first
            // system — the first shows long names, subsequent short.
            let labelW: CGFloat = isFirstSystem
                ? firstSystemLabelW : continuationLabelW
            // The CONTENT area starts after the label; measures must
            // fit within availableWidth − labelW.
            let contentAvail = context.availableWidth - labelW
            var widthSoFar: CGFloat = 0
            // The same measures at their natural width (`naturalWidth`), for the natural-stretch test.
            var naturalSoFar: CGFloat = 0
            let systemStart = cursor
            // Engraving convention redraws the active clef + key
            // signature at every system head. `minWidths[systemStart]`
            // only counts elements physically present in that measure,
            // so when wrapping promotes an interior measure to a system
            // head, the synthesised header eats into the chord content
            // area — squeezing adjacent lyrics together. Reserve the
            // synthesised overhead up front so the first measure keeps
            // its natural chord spacing.
            let firstHeaderBoost = synthHeaderOverhead(
                staves: staves,
                measureIdx: systemStart,
                activeKeys: activeKeys,
                metrics: context.metrics,
                leadingClefDrawnBefore: leadingClefDrawnBefore(
                    measureIdx: systemStart, staves: staves, plan: plan,
                ),
            )
            // MuseScore fills a line greedily: it adds measures while the
            // line's natural width still fits the page and closes it at the
            // first that does not (`SystemLayout::collectSystem`). The
            // natural width is each measure's gaps at `naturalStretch` with
            // everything else counted once (`naturalWidth`); at the default
            // stretch it reproduces MuseScore's line breaks across a corpus of
            // real scores better than any other value tried (2026-10-18). A
            // line used to be closed against `contentAvail / naturalStretch`
            // with every measure's whole width stretched — the header and the
            // room around the content too — and short spans between breaks
            // were split evenly; both packed fewer measures to a line than
            // MuseScore, which splits nothing evenly.
            while cursor < measureCount {
                // Multi-measure-rest interior indices contribute width 0 and emit
                // nothing; the run-start at `cursor.lowerBound` already accounted
                // for the collapsed width. Advance cursor past the interior in a
                // single jump so layout-break inspection stays anchored on the
                // run's start.
                if context.multiMeasureRestPlan.isInteriorOfRun(cursor) {
                    cursor += 1
                    // A run's last measure is interior: its break (authored, or a frame right after the run) ends
                    // the system here, as the check at the bottom of this loop does for a drawn measure.
                    if context.options.wrapToViewWidth,
                       cursor > systemStart,
                       measureForcesLineBreak(
                           at: cursor - 1, staves: staves, policy: context.options.breakPolicy,
                           frameBreaks: context.frameBreaks,
                       )
                    {
                        break
                    }
                    continue
                }
                let room = roomBefore(cursor, systemStart: systemStart, in: horizontalGaps)
                let baseW = minWidths[cursor] + room
                // Joining the line, this measure gives the one before it a
                // measure after it on the line, and that one its join growth.
                let joinW = cursor > systemStart ? joinGrowths[cursor - 1] : 0
                let w = cursor == systemStart
                    ? baseW + firstHeaderBoost
                    : baseW + joinW
                // An HBox's room does not stretch: against the line it costs its width once (MS adds a box 1:1
                // to `curSysWidth`).
                let naturalW = naturalWidth(cursor, w - room - joinW) + room
                    + (cursor > systemStart ? naturalJoinGrowth(cursor - 1) : 0)
                // Hard ceiling — never let a system overflow the
                // page horizontally.
                if context.options.wrapToViewWidth
                    && widthSoFar + w > contentAvail
                    && cursor > systemStart
                {
                    break
                }
                // Natural stretch break — close the system early
                // when adding the next measure would push our
                // stretch ratio below `naturalStretch`. Only
                // applies once the system already has at least
                // one measure (so single very-wide measures still
                // get a system to themselves).
                if context.options.wrapToViewWidth
                    && cursor > systemStart
                    && naturalSoFar + naturalW > contentAvail
                {
                    break
                }
                widthSoFar += w
                naturalSoFar += naturalW
                cursor += 1
                // Explicit `<LayoutBreak><subtype>line</subtype>`
                // forces the next measure onto a new system —
                // ONLY in wrap-to-width mode. Horizontal /
                // single-line layouts ignore line breaks, mirroring
                // MuseScore's `LayoutMode::LINE` /
                // `LayoutMode::HORIZONTAL_FIXED` branch in
                // `engraving/rendering/score/systemlayout.cpp:265-269`
                // where `lineBreak = false` regardless of the flag.
                // Line breaks are document-level (every staff agrees),
                // so we check staff 0.
                if context.options.wrapToViewWidth,
                   cursor > systemStart,
                   measureForcesLineBreak(
                       at: cursor - 1,
                       staves: staves,
                       policy: context.options.breakPolicy,
                       frameBreaks: context.frameBreaks,
                   )
                {
                    break
                }
            }
            // A measure-repeat group stays on one system (`measureRepeatGroupStart`): a line the width closed inside
            // one ends before the group instead — unless the group opens the line, which then has to hold what fits,
            // and unless an authored break chose the split.
            if context.options.wrapToViewWidth, cursor < measureCount,
               !measureForcesLineBreak(
                   at: cursor - 1, staves: staves, policy: context.options.breakPolicy,
                   frameBreaks: context.frameBreaks,
               ),
               let groupStart = measureRepeatGroupStart(splitAt: cursor, staves: staves), groupStart > systemStart
            {
                for idx in groupStart ..< cursor {
                    widthSoFar -= minWidths[idx] + roomBefore(idx, systemStart: systemStart, in: horizontalGaps)
                        + joinGrowths[idx - 1]
                }
                cursor = groupStart
            }
            // The system's trailing edge announces the next system's
            // opening signature change. The inner loop above filled the
            // system without knowing that, so give the announcement back
            // its room here: drop trailing measures until it fits.
            // Bounded by the one-measure floor — a lone measure keeps its
            // system even when the announcement overflows, exactly as the
            // hard ceiling lets a single over-wide measure through.
            if context.options.wrapToViewWidth {
                while cursor - systemStart > 1,
                      let courtesy = courtesies[cursor - 1],
                      widthSoFar + courtesy.width > contentAvail
                {
                    // Step back one DRAWN measure: past a whole
                    // multi-measure-rest run rather than into the middle
                    // of one, whose interiors carry no width and emit
                    // nothing without their run-start.
                    var candidate = cursor - 1
                    while candidate > systemStart,
                          plan.isInteriorOfRun(candidate)
                    {
                        candidate -= 1
                    }
                    guard candidate > systemStart else { break }
                    for idx in candidate ..< cursor {
                        widthSoFar -= minWidths[idx] + roomBefore(idx, systemStart: systemStart, in: horizontalGaps)
                            + joinGrowths[idx - 1]
                    }
                    cursor = candidate
                }
            }
            // `courtesies` is nil at the score's last measure, so a
            // system that runs to the end announces nothing.
            let trailingCourtesy = courtesies[cursor - 1]
            var widthsSlice = Array(minWidths[systemStart ..< cursor])
            if !widthsSlice.isEmpty {
                widthsSlice[0] += firstHeaderBoost
            }
            // Every measure but the last has the next one after it on the line, and is spaced and placed as joined.
            let lineAggregates: [TickAggregate?] = widthsSlice.indices.map { j in
                j < widthsSlice.count - 1 ? joinedAggregates[systemStart + j] : nil
            }
            for j in widthsSlice.indices.dropLast() {
                widthsSlice[j] += joinGrowths[systemStart + j]
            }
            // Reserve the announcement on the last measure that actually
            // draws — a multi-measure-rest run's interior indices carry
            // width 0 and emit nothing, so the reservation belongs on the
            // run's start instead.
            if let courtesy = trailingCourtesy,
               let last = widthsSlice.indices.last(where: {
                   !plan.isInteriorOfRun(systemStart + $0)
               })
            {
                widthsSlice[last] += courtesy.width
            }
            // Each measure at its natural width (`naturalWidth`): only its gaps stretched, so the system head's
            // header is no wider than a header in the middle of a line.
            //
            // Never below the minimum, though: a stretch under 1
            // (a host packing music densely) would otherwise draw
            // each measure narrower than its own content — every
            // column past the barline and into the next measure.
            // Below 1 the measure simply stays at its minimum,
            // as a wrapped system's hard ceiling already makes it.
            let naturalWidths = widthsSlice.indices.map { j in
                max(widthsSlice[j], naturalWidth(systemStart + j, widthsSlice[j], joined: lineAggregates[j] != nil))
            }
            let stretched: [CGFloat]
            if context.options.wrapToViewWidth,
               shouldJustify(
                   naturalWidth: labelW + naturalWidths.reduce(0, +)
                       + roomInside(systemStart ..< cursor, gaps: horizontalGaps),
                   availableWidth: context.availableWidth,
                   endsMusic: endsMusic(
                       before: cursor, measureCount: measureCount, staves: staves, policy: context.options.breakPolicy,
                   ),
               )
            {
                // A collapsed multi-measure rest, or a bar with nothing timed in it, has no gaps to stretch.
                let springs = widthsSlice.indices.map { j -> TickAggregate? in
                    let i = systemStart + j
                    guard plan.runLength(startingAt: i) == nil, !plan.isInteriorOfRun(i),
                          let aggregate = lineAggregates[j] ?? aggregates[i], aggregate.totalWeight > 0
                    else { return nil }
                    return aggregate
                }
                stretched = justifiedWidths(
                    widths: widthsSlice,
                    springs: springs,
                    availableWidth: contentAvail - roomInside(systemStart ..< cursor, gaps: horizontalGaps),
                    sp: sp,
                )
            } else {
                // Horizontal (no-wrap) mode: there's no viewport
                // width to stretch into, so without a fixed scale
                // measures collapse to their minimums. Each takes its
                // natural width instead — the width the wrapped
                // layout packs lines by — as MuseScore's continuous
                // view lays measures out at theirs. A wrapped line
                // that is not justified keeps the same widths.
                stretched = naturalWidths
            }
            // HBox room joins its measure's slot only now, so no stretch scales it; `buildSystem` takes it back out.
            let slots = slotsWithRoom(stretched, systemStart: systemStart, gaps: horizontalGaps)
            // Snapshot carry-in state BEFORE buildSystem mutates it.
            // Used either as cache key (on miss store) or for hit check.
            let activeClefsIn = activeClefs
            let activeKeysIn = activeKeys
            let measureCount = cursor - systemStart
            let inputs = systemInputs(
                measureStart: systemStart,
                measureCount: measureCount,
                widths: slots,
                isFirstSystem: isFirstSystem,
                activeClefsIn: activeClefsIn,
                activeKeysIn: activeKeysIn,
                trailingCourtesy: trailingCourtesy,
                lineAggregates: lineAggregates,
                context: context,
            )
            let system: LayoutSystem
            if let prior = priorSystemEntries[systemStart],
               prior.inputs == inputs
            {
                // Cache hit: reuse stored unshifted system + carry-out.
                system = shift(prior.system, byY: currentY)
                activeClefs = prior.activeClefsOut
                activeKeys = prior.activeKeysOut
                context.cache?.systemEntries[systemStart] = prior
                context.cache?.systemHits += 1
            } else {
                // Miss: build the system at originY = 0 (so the cache
                // entry is independent of vertical packing position),
                // then shift to currentY for placement.
                let unshifted = buildSystem(
                    measureRange: systemStart ..< cursor,
                    widths: slots,
                    systemOriginY: 0,
                    isFirstSystem: isFirstSystem,
                    trailingCourtesy: trailingCourtesy,
                    lineAggregates: lineAggregates,
                    activeClefs: &activeClefs,
                    activeKeys: &activeKeys,
                    widthPassAggregates: aggregates,
                    context: context,
                )
                system = shift(unshifted, byY: currentY)
                context.cache?.systemEntries[systemStart] = LayoutCache
                    .SystemEntry(
                        inputs: inputs,
                        system: unshifted,
                        activeClefsOut: activeClefs,
                        activeKeysOut: activeKeys,
                    )
                context.cache?.systemMisses += 1
            }
            currentY += system.size.height + context.options.systemGap
            systems.append(system)
            isFirstSystem = false
        }
        return systems
    }

    /// Every input a measure's natural width and tick aggregate are derived from — the cache-hit predicate of a width
    /// entry (`LayoutCache.Entry`). One value for both passes that read widths, `packSystems` and
    /// `naturalContentWidth(score:options:cache:)`, so the two cannot drift apart in what they compare.
    struct WidthInputs {
        let measures: [Measure?]
        let sp: CGFloat
        let division: Int
        let spacing: EngravingSpacing
        let graceNoteMag: CGFloat
        let chordSymbolCase: ChordSymbolCaseStyle
        let measureDuration: Fraction
        let followingClefs: [FollowingClef?]
        let leadingClefDrawnBefore: Bool

        init(
            measureIdx: Int, staves: [Staff], measureDuration: Fraction, metrics: StaffMetrics, division: Int,
            options: ScoreViewOptions, chordSymbolCase: ChordSymbolCaseStyle,
        ) {
            measures = staves.map { staff in
                measureIdx < staff.measures.count ? staff.measures[measureIdx] : nil
            }
            sp = metrics.sp
            self.division = division
            spacing = options.spacing
            graceNoteMag = options.graceNoteMag
            self.chordSymbolCase = chordSymbolCase
            self.measureDuration = measureDuration
            followingClefs = LayoutEngine.followingClefs(after: measureIdx, staves: staves, plan: nil)
            leadingClefDrawnBefore = LayoutEngine.leadingClefDrawnBefore(
                measureIdx: measureIdx, staves: staves, plan: nil,
            )
        }
    }

    /// One measure's width-pass entry, computed afresh — what a width pass
    /// stores on a cache miss: the natural width and the aggregate behind it,
    /// keyed by every input that went into them.
    static func widthEntry(
        measureIdx: Int, inputs: WidthInputs, staves: [Staff], metrics: StaffMetrics,
    ) -> LayoutCache.Entry {
        let baseHeader = computeHeaderSchedule(
            measureIdx: measureIdx, staves: staves, metrics: metrics,
            synthesizeClefForAllStaves: false, synthesizeKeySigForAllStaves: false,
            leadingClefDrawnBefore: inputs.leadingClefDrawnBefore,
        )
        let result = crossStaffMinimumMeasureWidthWithAggregate(
            staves: staves,
            measureIdx: measureIdx,
            metrics: metrics,
            headerSchedule: baseHeader,
            division: inputs.division,
            measureDuration: inputs.measureDuration,
            graceNoteMag: inputs.graceNoteMag,
            chordSymbolCase: inputs.chordSymbolCase,
        )
        return LayoutCache.Entry(
            measures: inputs.measures,
            sp: inputs.sp,
            division: inputs.division, spacing: inputs.spacing,
            graceNoteMag: inputs.graceNoteMag,
            chordSymbolCase: inputs.chordSymbolCase,
            measureDuration: inputs.measureDuration,
            followingClefs: inputs.followingClefs,
            leadingClefDrawnBefore: inputs.leadingClefDrawnBefore,
            minWidth: result.width,
            tickAggregate: result.aggregate,
            placements: [:],
        )
    }

    /// Resolve each staff's starting-of-score default clef from the
    /// part's declarations.  Mirrors the logic used previously inside
    /// `buildSystem`; factored out so `packSystems` can initialize the
    /// clef carry-over state before entering the system loop.
    ///
    /// Previously used a flat staff index to look up the part, which
    /// broke for multi-staff parts (e.g. Piano): staff index 1 would
    /// resolve to the second part instead of the second staff inside
    /// the first part. `StaffAddress` carries both `partIndex` and
    /// `staffIndexInPart`, so the lookup is now correct.
    static func defaultClefRawTypes(
        addresses: [(address: StaffAddress, staff: Staff)],
    ) -> [String] {
        addresses.map { entry in
            let staff = entry.staff
            if let declared = staff.defaultClefType {
                return declared
            }
            if staff.group == "percussion" { return "PERC" }
            return "G"
        }
    }

    /// Build a `LayoutCache.SystemInputs` snapshot for the given
    /// system. The snapshot is the cache-hit predicate — every input
    /// that affects `buildSystem` output (apart from `systemOriginY`,
    /// which is normalized away) must appear here.
    static func systemInputs(
        measureStart: Int,
        measureCount: Int,
        widths: [CGFloat],
        isFirstSystem: Bool,
        activeClefsIn: [NotatedClef],
        activeKeysIn: [Int],
        trailingCourtesy: TrailingCourtesy?,
        lineAggregates: [TickAggregate?] = [],
        context: RenderContext,
    ) -> LayoutCache.SystemInputs {
        let allStaves = context.score.allStaves
        let staves = allStaves.map(\.staff)
        let measuresPerStaff: [[Measure?]] = staves.map { staff in
            (0 ..< measureCount).map { local in
                let abs = measureStart + local
                return abs < staff.measures.count
                    ? staff.measures[abs] : nil
            }
        }
        // The lane can be shorter than the measure count (a score that
        // carries no system elements leaves it empty), so index it
        // defensively rather than assuming it parallels the measures —
        // the same guard `buildSystem` uses when it reads the lane.
        let systemMeasuresForRange: [SystemMeasure] = (0 ..< measureCount)
            .map { local in
                let abs = measureStart + local
                return abs < context.score.systemMeasures.count
                    ? context.score.systemMeasures[abs] : SystemMeasure()
            }
        let melismaForRange: [[[MelismaContinuation]]]
        melismaForRange = (0 ..< staves.count).map { staffIdx in
            (0 ..< measureCount).map { local in
                let abs = measureStart + local
                guard staffIdx < context.melismaContinuations.count,
                      abs < context.melismaContinuations[staffIdx].count
                else { return [] }
                return context.melismaContinuations[staffIdx][abs]
            }
        }
        let instruments = allStaves.map { context.score.parts[$0.address.partIndex].instrument }
        let drumLineMaps: [[Int: Int]?] = instruments.map { $0.useDrumset ? $0.drumLineMap : nil }
        // Anchors that reach into `[measureStart, lastMeasure]` from
        // anywhere, including from before it.
        let lastMeasure = measureStart + measureCount - 1
        let overlappingAnchors = context.spannerAnchors.filter {
            $0.startMeasure <= lastMeasure
                && max($0.startMeasure, $0.endMeasure) >= measureStart
        }
        return LayoutCache.SystemInputs(
            measureStart: measureStart,
            measureCount: measureCount,
            widths: widths,
            isFirstSystem: isFirstSystem,
            activeClefsIn: activeClefsIn,
            activeKeysIn: activeKeysIn,
            sp: context.metrics.sp,
            availableWidth: context.availableWidth,
            division: context.score.division,
            measuresPerStaff: measuresPerStaff,
            systemMeasuresForRange: systemMeasuresForRange,
            melismaContinuationsForRange: melismaForRange,
            drumLineMaps: drumLineMaps,
            drumNoteheads: instruments.map(\.drumNoteheads),
            percussionGroups: staves.map { $0.group == "percussion" },
            partLabels: partLabels(of: context.score, isFirstSystem: isFirstSystem),
            totalMeasures: staves.first?.measures.count ?? 0,
            options: context.options,
            overlappingSpannerAnchors: overlappingAnchors,
            ottavaNumbersOnly: context.score.style.ottavaNumbersOnly,
            chordSymbolCase: context.score.style.chordSymbolCase,
            trailingCourtesy: trailingCourtesy,
            followingClefs: followingClefs(after: lastMeasure, staves: staves, plan: context.multiMeasureRestPlan),
            lineAggregates: lineAggregates,
        )
    }

    /// The part label each part contributes to a system — the same resolution
    /// `buildSystem` performs to draw it and `labelWidth` performs to reserve
    /// the opening indent, spelled once here so the cache key cannot disagree
    /// with either of them.
    static func partLabels(of score: Score, isFirstSystem: Bool) -> [String] {
        score.parts.map { part in
            isFirstSystem
                ? (part.instrument.longName ?? part.trackName ?? "")
                : (part.instrument.shortName ?? "")
        }
    }

    /// MuseScore's `Sid::lastSystemFillLimit` default: a line the music ends on is justified only when its natural
    /// width fills at least this much of the page.
    static let lastSystemFillLimit: CGFloat = 0.3

    /// Whether a wrapped system is stretched across the line (`justifiedWidths`) or left at its natural width — the
    /// latter only for the line a piece or a section ends on (`endsMusic`) whose natural width, part labels and HBox
    /// room included, fills less than `lastSystemFillLimit` of `availableWidth`, as `SystemLayout::shouldBeJustified`
    /// decides. Stretching one bar of four quarters across a whole line set them a quarter of the page apart.
    static func shouldJustify(naturalWidth: CGFloat, availableWidth: CGFloat, endsMusic: Bool) -> Bool {
        guard endsMusic, availableWidth > 0 else { return true }
        return naturalWidth / availableWidth >= lastSystemFillLimit
    }

    /// Whether the system closing before bar `cursor` is the line a piece or a section ends on, for `shouldJustify`.
    ///
    /// Not the piece's last line when its last bar carries a break the layout honors (`measureForcesLineBreak`, no
    /// frames): that break comes before nothing, so it is taken to ask for what a break leaves every other line —
    /// a full line. A frame after the last bar is not such a break; MuseScore justifies past nothing but a measure or
    /// an HBox. A section break's line is left alone, since a line break is how a section is ended on its own line.
    static func endsMusic(before cursor: Int, measureCount: Int, staves: [Staff], policy: LayoutBreakPolicy) -> Bool {
        guard cursor == measureCount else { return staves.first?.measures[cursor - 1].sectionBreak == true }
        return !measureForcesLineBreak(at: cursor - 1, staves: staves, policy: policy)
    }

    /// The widths a wrapped system's measures take when the system is justified to `availableWidth`; `widths` itself
    /// when they already fill it.
    ///
    /// MuseScore justifies a system with one spring per chord/rest segment across the whole line
    /// (`HorizontalSpacing::justifySystem` → `stretchSegmentsToWidth`): a spring's constant comes from its duration
    /// and its pre-tension from the width a collision already pushed it to, so the leftover room goes to the segments
    /// still at their natural width first, and equal durations end up equally wide all along the line. A measure's
    /// gaps are already such springs here (`max(floor, k · weight)`, `TickAggregate.contentWidth(atStretch:)`), so the
    /// system finds the one stretch `k` every measure shares. Scaling each measure by one ratio instead — what this
    /// did before — handed a measure more of the leftover the wider its minimum was, for a header, a syllable's room or
    /// an accidental, and its notes stood further apart than the same rhythm's in the next bar.
    ///
    /// What does not stretch keeps its width: the header, the room around the content, a courtesy announcement.
    /// `springs[j]` is `nil` for a measure with no gaps to stretch — a collapsed multi-measure rest — which scales
    /// with `k` as a whole instead.
    static func justifiedWidths(
        widths: [CGFloat], springs: [TickAggregate?], availableWidth: CGFloat, sp: CGFloat,
    ) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard total > 0, availableWidth > total else { return widths }
        // The least content width a measure is given, as `crossStaffMinimumMeasureWidthWithAggregate` gives it.
        let contentFloor = sp * 4
        func width(_ j: Int, atStretch k: CGFloat) -> CGFloat {
            guard let spring = springs[j] else { return widths[j] * k }
            let minimum = max(contentFloor, spring.minimumContentWidth)
            let content = max(contentFloor, spring.contentWidth(atStretch: k))
            // `tickColumns` gives a measure at its minimum width one sp more content than its minimum, so a measure
            // starts to widen only once the line's stretch passes the one it already has there; from then on its
            // gaps are exactly `content`.
            return widths[j] + max(0, content - minimum - sp)
        }
        func totalWidth(atStretch k: CGFloat) -> CGFloat {
            widths.indices.reduce(0) { $0 + width($1, atStretch: k) }
        }
        var low: CGFloat = 1
        var high: CGFloat = 2
        var doublings = 0
        while totalWidth(atStretch: high) < availableWidth {
            low = high
            high *= 2
            doublings += 1
            // Nothing on the line stretches far enough (every gap held by a floor that never yields): scale it.
            guard doublings < 64 else { return widths.map { $0 * availableWidth / total } }
        }
        for _ in 0 ..< 64 {
            let mid = (low + high) / 2
            if totalWidth(atStretch: mid) < availableWidth { low = mid } else { high = mid }
        }
        var justified = widths.indices.map { width($0, atStretch: high) }
        // What the search leaves over, a rounding error, goes to the last measure so the line ends where it must.
        if let last = justified.indices.last {
            justified[last] += availableWidth - justified.reduce(0, +)
        }
        return justified
    }
}
