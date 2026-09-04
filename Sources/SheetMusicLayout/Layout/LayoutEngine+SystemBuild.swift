// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// One measure of one system, after `placeMeasureElements` and
    /// before the pass-2 translation into system coordinates: X is
    /// measure-local, Y is staff-local (staff top at `sp * 2`).
    ///
    /// Declared at type level rather than inside `buildSystem` so
    /// `synthesizeLineSpanners` can insert into the same buffer.
    struct UntranslatedMeasure {
        let measureIdx: Int
        /// The measure's full horizontal advance, including any
        /// end-of-system courtesy reservation at its trailing edge.
        let width: CGFloat
        /// Where the measure's own content ends — `width` minus the
        /// courtesy reservation, and so where the end barline sits.
        /// Equal to `width` for every measure that announces nothing.
        let contentWidth: CGFloat
        var perStaffElements: [Int: [LayoutElement]]
        /// Hidden annotations laid out under `showsInvisibleElements`,
        /// kept parallel to `perStaffElements` so the system-wide
        /// post-passes (lyric/melisma Y align) leave them alone.
        var perStaffInvisibleElements: [Int: [LayoutElement]]
        let staff0Measure: Measure?
        let tickCols: [Int: CGFloat]
        /// When non-nil, this entry is a multi-measure-rest run-start
        /// placeholder. Pass 2 emits a single H-bar LayoutMeasure for
        /// the run instead of the per-staff aggregation. The value is
        /// the source-measure count covered by the run.
        let multiMeasureRestCount: Int?
    }

    // MARK: - Per-system layout

    static func buildSystem( // swiftlint:disable:this function_body_length
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        trailingCourtesy: TrailingCourtesy? = nil,
        activeClefs: inout [NotatedClef],
        activeKeys: inout [Int],
        context: RenderContext,
    ) -> LayoutSystem {
        let metrics = context.metrics
        let allStaves = context.score.allStaves
        let staves = allStaves.map(\.staff)
        // Per-staff line geometry, parallel to `staves` (and therefore
        // to `staffOrigins`). `metrics.staffHeight` remains the
        // five-line REFERENCE height that step→Y placement is expressed
        // in; these carry each staff's own DRAWN height, which is what
        // the vertical stack below must advance by.
        let staffGeometries = staves.map {
            StaffLineGeometry(lineCount: $0.lineCount)
        }
        let staffHeights = staffGeometries.map { $0.height(sp: metrics.sp) }
        // Bracket gutter inputs: max column index +1, plus the largest
        // brace `staffCount` so tall braces (`braceLarge` /
        // `braceLarger`, whose glyph width balloons with `magx`) don't
        // overrun the staff name area.
        let gutterInfo = bracketGutterInfo(score: context.score)
        let bracketColumnCount = gutterInfo.columnCount
        let maxBraceStaffCount = gutterInfo.maxBraceStaffCount
        let partLabelWidth: CGFloat = labelWidth(
            score: context.score,
            metrics: metrics,
            useLong: isFirstSystem,
            bracketColumnCount: bracketColumnCount,
            maxBraceStaffCount: maxBraceStaffCount,
        )

        // Inter-system breathing room. MuseScore's style defaults
        // (`engraving/style/styledef.cpp`):
        //   * `staffUpperBorder` = 7sp — but it acts only on a
        //     page's *first* system, not every system; `systemGap`
        //     (configured at the exporter / view level) handles the
        //     distance between consecutive systems.
        //   * `staffDistance` = 6.5sp — total gap between adjacent
        //     staves *within* a system.
        // Our previous `topPad = bottomPad = 6sp` double-counted
        // that distance and produced systems ~50% taller than
        // MuseScore. 1sp leaves a hairline so glyph extents that
        // overshoot the staff don't graze the system above / below.
        let topPad: CGFloat = metrics.sp * 1
        let bottomPad: CGFloat = metrics.sp * 1
        // Inter-staff vertical gap baseline. Combined with
        // `staffBottomPads[idx]` (lyrics / dynamics extent) and
        // the next staff's `staffTopPads` (2 sp baseline), this
        // approximates MuseScore's `Sid::staffDistance = 6.5 sp`.
        // 0.5 sp keeps total system height in line with
        // MuseScore's reference output without sacrificing
        // breathing room.
        let minGap: CGFloat = metrics.sp * 0.5

        // `staffBottomPads` is computed AFTER the untranslated
        // layout below — it depends on the actual south-skyline
        // Y of each staff (chord-pushed lyrics, melismas, etc.),
        // which only exists once `placeMeasureElements` has run.

        // --- Pass 1: place all measures untranslated ---
        //
        // Element auto-placement (e.g. `<StaffText>` getting bumped
        // above a high stem) makes each staff's vertical extent
        // dynamic — we can't size `staffTopPads` until we've seen
        // where the elements actually landed. Run `placeMeasureElements`
        // first into a per-staff buffer, then derive padding from
        // the resulting Y bounds, then translate in pass 2.
        // Per-staff effective measure durations so `placeMeasureElements`
        // receives the prevailing time signature (carried forward across
        // measures that contain no explicit `<TimeSignature>` element)
        // rather than deriving a local-scan-only fallback. Indexed as
        // `staffMeasureDurations[staffIdx]`. Read from the context — it
        // is built once at layout entry (see `LayoutEngine.layout`), NOT
        // once per system: `buildSystem` runs once per system, so
        // recomputing here would still be Θ(systems · staves · measures).
        let staffMeasureDurations = context.staffMeasureDurations
        // Cross-staff duration table for `tickColumns`, same
        // once-per-layout-call sourcing as `staffMeasureDurations` above.
        let sharedMeasureDurations = context.measureDurations
        var untranslated: [UntranslatedMeasure] = []
        var clefs = activeClefs
        var keys = activeKeys
        let plan = context.multiMeasureRestPlan
        // The measure that carries the end-of-system announcement: the
        // last one in the range that actually draws. A multi-measure-rest
        // run's interiors emit nothing, so the run's start announces for
        // them. `packSystems` reserved the width on the same index.
        let announcingMeasureIdx: Int? = trailingCourtesy == nil
            ? nil
            : measureRange.reversed().first { !plan.isInteriorOfRun($0) }
        for (j, measureIdx) in measureRange.enumerated() {
            if plan.isInteriorOfRun(measureIdx) {
                // Run-interior: collapsed-bar emission is owned by the
                // run-start. Don't compute placement, don't advance the
                // active clef/key carry-over (rule 1 in the spec excludes
                // clef/key changes inside a run).
                continue
            }
            if let runLen = plan.runLength(startingAt: measureIdx) {
                // Run-start: skip per-staff placement entirely. Pass 2 will
                // synthesize an H-bar LayoutMeasure of width `widths[j]`
                // (which Task 6 set to `collapsedRunWidth`).
                let staff0Measure: Measure? = measureIdx
                    < (staves.first?.measures.count ?? 0)
                    ? staves.first?.measures[measureIdx]
                    : nil
                untranslated.append(UntranslatedMeasure(
                    measureIdx: measureIdx,
                    width: widths[j],
                    contentWidth: widths[j] - courtesyReserve(
                        trailingCourtesy,
                        at: measureIdx,
                        announcingAt: announcingMeasureIdx,
                    ),
                    perStaffElements: [:],
                    perStaffInvisibleElements: [:],
                    staff0Measure: staff0Measure,
                    tickCols: [:],
                    multiMeasureRestCount: runLen,
                ))
                continue
            }
            // Placement lays the measure out inside its CONTENT width;
            // the announcement lives in the reserved band beyond it, so
            // the notes never spread into the glyphs that follow the
            // end barline.
            let fullWidth = widths[j]
            let w = fullWidth - courtesyReserve(
                trailingCourtesy,
                at: measureIdx,
                announcingAt: announcingMeasureIdx,
            )
            let synthesizeClefHere = j == 0
            let synthesizeKeySigHere = j == 0
            let schedule = computeHeaderSchedule(
                measureIdx: measureIdx,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: synthesizeClefHere,
                synthesizeKeySigForAllStaves: synthesizeKeySigHere,
                activeKeys: keys,
            )
            // Reuse the aggregate `crossStaffMinimumMeasureWidth`
            // already computed for this measure during `packSystems`'s
            // width pass instead of recomputing `aggregatedTickWeights`
            // a second time. Key: `measures`, `sp`, `division`, AND
            // `measureDuration` — see `LayoutCache.Entry.measureDuration`'s
            // doc for why the prevailing (carried-forward) duration must
            // be part of the predicate, not just the measure's own
            // (unchanged) content.
            //
            // This lookup is a MISS only when `context.cache` itself is
            // nil (caching disabled): `packSystems`'s width pass always
            // populates `entries[measureIdx]` — hit or miss — for every
            // index in `0 ..< measureCount` before any system is built,
            // so a real cache always finds an entry here.
            let cachedAggregate = context.cache?
                .entries[measureIdx]?.tickAggregate
            if cachedAggregate != nil {
                context.cache?.tickAggregateHits += 1
            }
            let aggregate = cachedAggregate ?? aggregatedTickWeights(
                staves: staves,
                measureIdx: measureIdx,
                metrics: metrics,
                division: context.score.division,
                measureDuration: measureDuration(
                    sharedMeasureDurations, at: measureIdx,
                ),
            )
            let tickCols = tickColumns(
                aggregate: aggregate,
                metrics: metrics,
                headerSchedule: schedule,
                width: w,
            )
            // `<endRepeat>` is a flag on the canonical staff's measure,
            // not a `<BarLine>` element, and it applies to the whole
            // system — so it is read once here rather than per staff.
            let endsRepeat = staves.first.map {
                measureIdx < $0.measures.count
                    && $0.measures[measureIdx].endRepeatCount != nil
            } ?? false
            var perStaff: [Int: [LayoutElement]] = [:]
            var perStaffInvisible: [Int: [LayoutElement]] = [:]
            var synthesizedEndBarLineIndices: [Int: Int] = [:]
            for (staffIdx, staff) in staves.enumerated() {
                guard measureIdx < staff.measures.count else { continue }
                let m = staff.measures[measureIdx]
                let synthClef: String? = synthesizeClefHere
                    ? clefs[staffIdx].rawType
                    : nil
                let synthKey: Int? = synthesizeKeySigHere
                    ? keys[staffIdx]
                    : nil
                let part = context.score.parts[allStaves[staffIdx].address.partIndex]
                let drumMap: [Int: Int]? =
                    part.instrument.useDrumset
                        ? part.instrument.drumLineMap
                        : nil
                let totalMeasures = staves.first?.measures.count ?? 0
                let lastMeasure = measureIdx == totalMeasures - 1
                let incomingMelismas = context.melismaContinuations
                    .indices.contains(staffIdx)
                    && context.melismaContinuations[staffIdx]
                    .indices.contains(measureIdx)
                    ? context.melismaContinuations[staffIdx][measureIdx]
                    : []
                let canonicalStaff = StaffAddress(
                    partIndex: 0, staffIndexInPart: 0,
                )
                let address = allStaves[staffIdx].address
                let systemElementsForStaff: [PositionedSystemElement] =
                    measureIdx < context.score.systemMeasures.count
                        ? context.score.systemMeasures[measureIdx].elements
                        .filter {
                            ($0.originalStaff ?? canonicalStaff) == address
                        }
                        : []
                let measDuration = measureDuration(
                    staffMeasureDurations[staffIdx], at: measureIdx,
                )
                let placementInputs = LayoutCache.PlacementInputs(
                    measure: m,
                    width: w,
                    metricsSp: metrics.sp,
                    activeClef: clefs[staffIdx],
                    activeKey: keys[staffIdx],
                    lineCount: staffGeometries[staffIdx].lineCount,
                    initialClefRawType: synthClef,
                    initialKeyForSynth: synthKey,
                    headerSchedule: schedule,
                    tickColumns: tickCols,
                    division: context.score.division,
                    drumLineMap: drumMap,
                    isLastMeasure: lastMeasure,
                    endsRepeat: endsRepeat,
                    isFirstSystem: isFirstSystem,
                    incomingMelismas: incomingMelismas,
                    effectiveMelismaTicks: context.effectiveMelismaTicks,
                    graceNoteMag: context.options.graceNoteMag,
                    systemElements: systemElementsForStaff,
                    showsInvisibleElements: context.options.showsInvisibleElements,
                    lyricsVisible: context.options.lyricsVisible,
                    measureDuration: measDuration,
                )
                let els: [LayoutElement]
                let invisibleEls: [LayoutElement]
                let synthesizedEndBarLineIndex: Int?
                let newClef: NotatedClef
                let newKey: Int
                if let cached = context.cache?
                    .entries[measureIdx]?.placements[staffIdx],
                    cached.inputs == placementInputs
                {
                    els = cached.elements
                    invisibleEls = cached.invisibleElements
                    synthesizedEndBarLineIndex = cached
                        .synthesizedEndBarLineIndex
                    newClef = cached.newClef
                    newKey = cached.newKey
                    context.cache?.placementHits += 1
                } else {
                    let result = placeMeasureElements(
                        measure: m,
                        staffAddress: allStaves[staffIdx].address,
                        measureIndex: measureIdx,
                        width: w,
                        metrics: metrics,
                        options: context.options,
                        activeClef: clefs[staffIdx],
                        activeKey: keys[staffIdx],
                        lineGeometry: staffGeometries[staffIdx],
                        initialClefRawType: synthClef,
                        initialKeyForSynth: synthKey,
                        headerSchedule: schedule,
                        tickColumns: tickCols,
                        division: context.score.division,
                        measureDuration: measDuration,
                        drumLineMap: drumMap,
                        isLastMeasure: lastMeasure,
                        endsRepeat: endsRepeat,
                        isFirstSystem: isFirstSystem,
                        incomingMelismas: incomingMelismas,
                        effectiveMelismaTicks: context.effectiveMelismaTicks,
                        systemElements: systemElementsForStaff,
                    )
                    els = result.elements
                    invisibleEls = result.invisibleElements
                    synthesizedEndBarLineIndex = result
                        .synthesizedEndBarLineIndex
                    newClef = result.clef
                    newKey = result.key
                    context.cache?.placementMisses += 1
                    if var entry = context.cache?.entries[measureIdx] {
                        entry.placements[staffIdx] = LayoutCache
                            .StaffPlacement(
                                inputs: placementInputs,
                                elements: els,
                                invisibleElements: invisibleEls,
                                synthesizedEndBarLineIndex: synthesizedEndBarLineIndex,
                                newClef: newClef,
                                newKey: newKey,
                            )
                        context.cache?.entries[measureIdx] = entry
                    }
                }
                clefs[staffIdx] = newClef
                keys[staffIdx] = newKey
                perStaff[staffIdx] = els
                if let synthesizedEndBarLineIndex {
                    synthesizedEndBarLineIndices[staffIdx] =
                        synthesizedEndBarLineIndex
                }
                if !invisibleEls.isEmpty {
                    perStaffInvisible[staffIdx] = invisibleEls
                }
            }
            // End-of-system courtesy signatures, in the band reserved
            // past the end barline. Appended AFTER the per-measure
            // placement cache is written above — like the measure number
            // below — so a cached `StaffPlacement` never carries an
            // announcement that belongs to a boundary it knows nothing
            // about. The clef is this staff's carry-out one, which the
            // loop above just settled, so a courtesy of a change to C
            // cancels at the positions that clef actually uses.
            if let courtesy = trailingCourtesy,
               measureIdx == announcingMeasureIdx
            {
                for staffIdx in staves.indices
                    where perStaff[staffIdx] != nil
                {
                    if !courtesy.keys.isEmpty,
                       let index = synthesizedEndBarLineIndices[staffIdx],
                       let element = perStaff[staffIdx]?[index],
                       case let .barLine(subtype, origin, halfHeight) = element,
                       subtype == nil
                    {
                        perStaff[staffIdx]?[index] = .barLine(
                            subtype: "double",
                            origin: origin,
                            halfHeight: halfHeight,
                        )
                    }
                    perStaff[staffIdx, default: []].append(
                        contentsOf: courtesyElements(
                            courtesy,
                            staffIndex: staffIdx,
                            contentWidth: w,
                            clef: clefs[staffIdx],
                            lineGeometry: staffGeometries[staffIdx],
                            metrics: metrics,
                        ),
                    )
                }
            }
            // Measure number — TOP STAFF ONLY. Engraving convention
            // places a single number above the topmost staff; how often
            // is `options.measureNumbers` (every system head by default,
            // optionally every N-th measure on top of that). Irregular
            // measures (anacrusis) suppress the label.
            //
            // The origin is measure-local, so an interval label lands
            // just left of its own leading barline exactly the way a
            // system-head label lands left of the system's.
            //
            // Emitted HERE rather than in pass 2 so the element sits in
            // the per-staff buffer the skyline autoplace pass operates
            // on. Staff-local Y: the staff top is at `sp * 2`, so
            // `sp * 2 - sp * 1.5` reproduces pass 2's
            // `staffOrigins[0].y - sp * 1.5` after translation.
            //
            // Appended AFTER the per-measure placement cache is written
            // above, so a cached `StaffPlacement` never carries a label
            // and toggling the policy cannot serve a stale one.
            if !staves.isEmpty,
               let displayed = context.score.displayedMeasureNumber(
                   at: measureIdx,
               ),
               context.options.measureNumbers.drawsLabel(
                   displayedNumber: displayed,
                   isSystemStart: untranslated.isEmpty,
               )
            {
                perStaff[0, default: []].append(.measureNumber(
                    text: "\(displayed)",
                    origin: CGPoint(
                        x: -metrics.sp * 0.5,
                        y: metrics.sp * 0.5,
                    ),
                ))
            }
            let staff0Measure: Measure? = measureIdx
                < (staves.first?.measures.count ?? 0)
                ? staves.first?.measures[measureIdx]
                : nil
            untranslated.append(UntranslatedMeasure(
                measureIdx: measureIdx,
                width: fullWidth,
                contentWidth: w,
                perStaffElements: perStaff,
                perStaffInvisibleElements: perStaffInvisible,
                staff0Measure: staff0Measure,
                tickCols: tickCols,
                multiMeasureRestCount: nil,
            ))
        }

        // --- System-wide lyric-Y alignment ---
        //
        // MuseScore's
        // `LyricsLayout::checkCollisionsWithStaffElements`
        // (`engraving/rendering/score/lyricslayout.cpp:614-651`)
        // walks the whole system, finds the deepest required
        // verse-Y, and shifts EVERY lyric in the verse uniformly
        // so the row stays horizontally aligned across the
        // system. `placeMeasureElements` only ratchets per
        // measure — across measures, lyric Y can still differ
        // (one measure has a low note that pushes lyrics down;
        // adjacent measures don't). This post-pass enforces the
        // system-wide max.
        for staffIdx in 0 ..< staves.count {
            // For each measure on this staff, the lowest Y among
            // its lyric elements is verse 0's Y (the
            // `maxLyricCenterYInMeasure` ratchet inside
            // `placeMeasureElements` gives all chords in the
            // measure the same Y base).
            var measureVerse0Y: [Int: CGFloat] = [:]
            for (mIdx, m) in untranslated.enumerated() {
                guard let els = m.perStaffElements[staffIdx]
                else { continue }
                var minY = CGFloat.infinity
                for el in els {
                    if case let .textMark(.lyrics, _, p) = el,
                       p.y < minY
                    {
                        minY = p.y
                    }
                }
                if minY != .infinity {
                    measureVerse0Y[mIdx] = minY
                }
            }
            guard let systemTargetY = measureVerse0Y.values.max()
            else { continue }
            // Per-measure shift for lyric text + hyphens: all
            // verses move uniformly so verse N stays at
            // `systemTargetY + N * 1.7sp`.
            for (mIdx, baseY) in measureVerse0Y
                where baseY < systemTargetY
            {
                let dy = systemTargetY - baseY
                if var els = untranslated[mIdx]
                    .perStaffElements[staffIdx]
                {
                    els = els.map { shiftLyricTextY($0, dy: dy) }
                    untranslated[mIdx]
                        .perStaffElements[staffIdx] = els
                }
            }
            // Melisma rules need an absolute snap, not a per-
            // measure shift. Anchor rules emitted in a chord-
            // pushed measure use that measure's pushed Y; the
            // continuation rule for the SAME melisma emitted in
            // the following measure (`emitMelismaContinuation`)
            // uses the default verse-0 Y because it has no view
            // of the originating chord. Without this snap the
            // continuation lands at default Y + dy_thisMeasure,
            // which only equals `systemTargetY + offset` when the
            // current measure has no own push. Force every
            // melisma in the system to `systemTargetY + 0.9 sp`
            // (the lyric font's underline level — see
            // `melismaLineYOffset`) so the rule sits flush with
            // the now-aligned lyric row, regardless of which
            // measure emitted it. Verse 0 only — multi-verse
            // melismas would need a verse hint on the element.
            let melismaTargetY = systemTargetY + metrics.sp * 0.9
            for mIdx in untranslated.indices {
                guard var els = untranslated[mIdx]
                    .perStaffElements[staffIdx] else { continue }
                els = els.map {
                    setMelismaAbsoluteY($0, y: melismaTargetY)
                }
                untranslated[mIdx]
                    .perStaffElements[staffIdx] = els
            }
        }

        // --- Skyline autoplace ---
        //
        // One pass per staff over the whole system, in MuseScore's
        // `layoutSystemElements` order. Runs after the lyric-Y
        // alignment above (so verse rows are already uniform) and
        // before the Y-bounds computation below (so `staffTopPads` /
        // `staffBottomPads` measure the POST-autoplace extents).
        // Horizontal coordinates are measure-local here, so the pass
        // receives each measure's accumulated system X.
        var contentWidth: CGFloat = partLabelWidth
        var xOffsets: [CGFloat] = []
        for um in untranslated {
            xOffsets.append(contentWidth)
            contentWidth += um.width
        }
        // --- Line spanners into the pass-1 buffer ---
        //
        // Before the autoplace block below, not after: its writeback
        // only touches staves that already have a buffer entry, so a
        // segment inserted later into a staff without one would be
        // dropped silently.
        synthesizeLineSpanners(
            into: &untranslated,
            anchors: context.spannerAnchors,
            measureRange: measureRange,
            staffCount: staves.count,
            staffGeometries: staffGeometries,
            xOffsets: xOffsets,
            systemWidth: contentWidth,
            ottavaNumbersOnly: context.score.style.ottavaNumbersOnly,
            metrics: metrics,
        )

        do {
            for staffIdx in 0 ..< staves.count {
                // The staff's OWN drawn band: placement puts the top
                // line at `sp * 2`, and a staff that draws `n` lines
                // ends its own height below that (zero for one line).
                // `metrics.staffHeight` is the five-line REFERENCE
                // height and would overshoot.
                let staffTopLocal = metrics.sp * 2
                let staffBottomLocal = staffTopLocal
                    + staffHeights[staffIdx]
                var perStaff: [[LayoutElement]] = untranslated.map {
                    $0.perStaffElements[staffIdx] ?? []
                }
                // Horizontal first: an annotation that overflows the
                // system's right edge is pulled back inside before the
                // vertical pass measures anything, so the stack it
                // computes reflects the X the renderer will actually
                // draw at.
                HorizontalClampPass.run(
                    measures: &perStaff,
                    xOffsets: xOffsets,
                    systemLeftX: xOffsets.first ?? 0,
                    systemRightX: contentWidth,
                    metrics: metrics,
                )
                SkylineAutoplacePass.run(
                    measures: &perStaff,
                    xOffsets: xOffsets,
                    systemRightX: contentWidth,
                    staffTop: staffTopLocal,
                    staffBottom: staffBottomLocal,
                    metrics: metrics,
                )
                for (mIdx, els) in perStaff.enumerated()
                    where untranslated[mIdx]
                    .perStaffElements[staffIdx] != nil
                {
                    untranslated[mIdx]
                        .perStaffElements[staffIdx] = els
                }
            }
        }

        // --- Per-staff Y bounds from the untranslated elements ---
        //
        // Mirrors MuseScore's "skyline" — the highest and lowest
        // points each staff actually paints, which feeds the
        // adaptive staff distance below. Staff top in placement
        // coords sits at `sp * 2` (see `staffMidY` in
        // `placeMeasureElements`); the bottom is at `sp * 6` for
        // a 5-line staff. Anything outside that range pushes the
        // adjacent staff away so they don't overlap.
        //
        // The bottom is per-staff: a staff that draws fewer lines
        // occupies a shorter band, so ink that a five-line staff would
        // have contained now counts as south overflow and correctly
        // widens the gap below it.
        let staffTopLocal: CGFloat = metrics.sp * 2
        let staffBottomLocals: [CGFloat] = staffHeights.map {
            staffTopLocal + $0
        }
        var staffMinY = Array(
            repeating: CGFloat.infinity, count: staves.count,
        )
        var staffMaxY = Array(
            repeating: -CGFloat.infinity, count: staves.count,
        )
        for um in untranslated {
            for (staffIdx, els) in um.perStaffElements {
                for el in els {
                    for y in elementYPoints(el, sp: metrics.sp) {
                        if y < staffMinY[staffIdx] {
                            staffMinY[staffIdx] = y
                        }
                        if y > staffMaxY[staffIdx] {
                            staffMaxY[staffIdx] = y
                        }
                    }
                }
            }
        }

        // --- Adaptive per-staff top padding ---
        let staffTopPads: [CGFloat] = staves.indices.map { idx in
            let topOverflow: CGFloat = staffMinY[idx].isFinite
                ? max(
                    0,
                    staffTopLocal - staffMinY[idx]
                        + metrics.sp * 0.5,
                )
                : 0
            // First staff falls under the system's `topPad`
            // already. For subsequent staves, MuseScore's
            // `Sid::staffDistance = 6.5 sp` is the total gap
            // between adjacent staves. We split that across
            // `staffBottomPads[idx-1] + minGap + this baseline`,
            // so the baseline carries roughly 2 sp of clearance
            // — enough that the upper staff's lyrics or staff-
            // text dynamics don't visually fuse with this
            // staff's top line.
            let baseline: CGFloat = idx == 0 ? 0 : metrics.sp * 2
            return baseline + topOverflow
        }

        // --- Adaptive per-staff bottom padding ---
        //
        // Two sources feed the gap below a staff:
        //   - A verse-count estimate that matches MuseScore's
        //     default `Sid::staffDistance = 6.5 sp` for a staff
        //     with one verse (1.5 sp `lyricsMinBottomDistance` +
        //     1.7 sp verse stride; see
        //     `engraving/style/styledef.cpp:92-99`).
        //   - The measured south skyline (`staffMaxY`), which
        //     captures chord-pushed lyrics + melisma rules +
        //     hyphens that can dip well below the verse-count
        //     estimate when low notes / ties are present.
        //
        // We take the max so the default case stays page-count
        // compatible with MuseScore while chord-pushed measures
        // get the extra room they need (see
        // `LyricsLayout::addToSkyline`,
        // `lyricslayout.cpp:707`).
        let staffBottomPads: [CGFloat] = staves.enumerated().map { idx, staff in
            var maxLyricsVerses = 0
            for mIdx in measureRange {
                guard mIdx < staff.measures.count else { continue }
                for voice in staff.measures[mIdx].voices {
                    for el in voice.elements {
                        if case let .chord(c) = el {
                            let nonEmpty = c.lyrics.count(where: {
                                !$0.text.isEmpty
                            })
                            maxLyricsVerses = max(
                                maxLyricsVerses, nonEmpty,
                            )
                        }
                    }
                }
            }
            let basePad: CGFloat = metrics.sp * 2.5
            let lyricsEstimate: CGFloat = maxLyricsVerses > 0
                ? metrics.sp * 1.5
                + CGFloat(maxLyricsVerses) * metrics.sp * 1.7
                : 0
            let southExtent: CGFloat = staffMaxY[idx].isFinite
                ? max(0, staffMaxY[idx] - staffBottomLocals[idx])
                : 0
            // Clearance constant stays smaller than MuseScore's
            // raw `lyricsMinBottomDistance = 1.5 sp` because our
            // `staffTopPads` baseline already adds another ~2 sp
            // above the next staff — together they reach the
            // 1.5 sp lyric-bottom-to-next-staff minimum without
            // bloating the page count. The same 0.5 sp matches
            // MuseScore's `Sid::minVerticalDistance` for general
            // skyline padding (`styledef.cpp:772`).
            let measuredPad = southExtent + metrics.sp * 0.5
            return max(basePad, lyricsEstimate, measuredPad)
        }

        // --- Compute staffOrigins from cumulative extent ---
        var staffOrigins: [CGPoint] = []
        var currentY: CGFloat = topPad
        for idx in 0 ..< staves.count {
            currentY += staffTopPads[idx]
            staffOrigins.append(CGPoint(
                x: partLabelWidth, y: currentY,
            ))
            if idx < staves.count - 1 {
                // Advance past the staff just placed, by ITS drawn
                // height — a 1-line staff leaves the next staff 4 sp
                // higher than a 5-line one would.
                currentY += staffHeights[idx]
                    + staffBottomPads[idx] + minGap
            }
        }

        // Build LayoutBrackets — one per visible BracketItem on each
        // staff. `span` overshooting the last staff is silently
        // clamped, mirroring MuseScore's `BracketItem::staffIdx2`.
        var brackets: [LayoutBracket] = []
        for (partIdx, part) in context.score.parts.enumerated() {
            guard let partFirstFlat = allStaves.firstIndex(where: {
                $0.address.partIndex == partIdx
            }) else { continue }
            for (staffIdxInPart, staff) in part.staves.enumerated() {
                let originFlat = partFirstFlat + staffIdxInPart
                guard originFlat < staffOrigins.count else { continue }
                for bi in staff.brackets where bi.visible
                    && bi.type != .noBracket
                {
                    let endFlat = min(
                        originFlat + bi.span - 1,
                        staffOrigins.count - 1,
                    )
                    let topY = staffOrigins[originFlat].y
                    // Bottom edge of the LAST spanned staff, by its
                    // own drawn height.
                    let bottomY = staffOrigins[endFlat].y
                        + staffHeights[endFlat]
                    brackets.append(LayoutBracket(
                        type: bi.type,
                        topY: topY,
                        bottomY: bottomY,
                        column: bi.column,
                        staffCount: endFlat - originFlat + 1,
                    ))
                }
            }
        }

        // Per-Part labels. Multi-staff parts (Piano grand staff)
        // collapse to a single label centered between the topmost
        // and bottommost spanned staves, matching engraving
        // convention. Single-staff parts trivially center on their
        // one staff.
        let labels: [LayoutPartLabel] = context.score.parts.enumerated().compactMap { partIdx, part in
            let text: String
            if isFirstSystem {
                text = part.instrument.longName
                    ?? part.trackName
                    ?? ""
            } else {
                text = part.instrument.shortName ?? ""
            }
            // Locate the part's flat-staff range. A part with no
            // entries in `allStaves` (shouldn't normally happen — a
            // Part declares staves that always end up flattened)
            // is skipped silently.
            guard let firstFlat = allStaves.firstIndex(where: {
                $0.address.partIndex == partIdx
            }), let lastFlat = allStaves.lastIndex(where: {
                $0.address.partIndex == partIdx
            }) else { return nil }
            let topY = staffOrigins[firstFlat].y
            // Bottom edge of the part's last staff, by its own drawn
            // height, so a multi-staff label stays centered on the
            // ink it labels.
            let bottomY = staffOrigins[lastFlat].y
                + staffHeights[lastFlat]
            let centerY = (topY + bottomY) / 2
            // Right-edge X for the trailing-anchored label glyphs.
            // Sits one `sp` left of the staff plus one extra `sp`
            // per bracket column, so the rightmost glyph never
            // overlaps a brace or angle bracket spine. For tall
            // braces (`staffCount ≥ 3`) the glyph width exceeds the
            // column-only allowance — `extraBraceShift` pushes the
            // label further left to maintain a 0.5 sp clearance from
            // the brace's left edge (right edge sits 0.3 sp inside
            // `staffOriginX`, glyph extends `glyphHorizontalExtent`
            // further to the left).
            let braceExtent = maxBraceStaffCount > 0
                ? BraceMetrics.glyphHorizontalExtent(
                    staffCount: maxBraceStaffCount, sp: metrics.sp,
                )
                : 0
            let extraBraceShift = max(
                0,
                braceExtent
                    - metrics.sp * 0.2
                    - CGFloat(bracketColumnCount) * metrics.sp,
            )
            let labelRightX = partLabelWidth
                - metrics.sp
                - CGFloat(bracketColumnCount) * metrics.sp
                - extraBraceShift
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: labelRightX, y: centerY),
            )
        }

        // --- Line spanners out of the pass-1 buffer ---
        let systemSpanners = extractLineSpanners(
            from: &untranslated,
            staffOrigins: staffOrigins,
            partLabelWidth: partLabelWidth,
            metrics: metrics,
        )

        // --- Pass 2: translate elements with adjusted origins ---
        var layoutMeasures: [LayoutMeasure] = []
        var xCursor: CGFloat = partLabelWidth
        for um in untranslated {
            if let runLen = um.multiMeasureRestCount {
                // Determine barline subtype from the last source measure of
                // the run. All staves agree on barline subtype (rule 1 of
                // collapsibility excludes per-staff content differences).
                // Mirrors the placeMeasureElements convention: prefer the
                // last explicit `<BarLine>` voice element, otherwise fall
                // back to "end" (thin + thick) when the run ends at the
                // score's final measure, otherwise nil (single line).
                let lastMeasureIdx = um.measureIdx + runLen - 1
                let totalMeasures = staves.first?.measures.count ?? 0
                let isLastMeasureOfScore = lastMeasureIdx == totalMeasures - 1
                var barSubtype: String?
                var runEndsRepeat = false
                if let firstStaff = staves.first,
                   lastMeasureIdx < firstStaff.measures.count
                {
                    let lastMeasure = firstStaff.measures[lastMeasureIdx]
                    runEndsRepeat = lastMeasure.endRepeatCount != nil
                    for voice in lastMeasure.voices {
                        for el in voice.elements {
                            if case let .barLine(b) = el {
                                barSubtype = b.subtype
                            }
                        }
                    }
                }
                // Same precedence the per-measure path uses: an explicit
                // `<BarLine>` wins, then the `<endRepeat>` flag, then the
                // score-final "end", then the courtesy-key double.
                if barSubtype == nil, runEndsRepeat {
                    barSubtype = "end-repeat"
                }
                if barSubtype == nil, isLastMeasureOfScore {
                    barSubtype = "end"
                }
                if barSubtype == nil,
                   um.measureIdx == announcingMeasureIdx,
                   let courtesy = trailingCourtesy,
                   !courtesy.keys.isEmpty
                {
                    barSubtype = "double"
                }

                // Emit one H-bar + one barline per staff.
                // Count text appears only above the top staff (count == 0
                // on lower staves instructs the renderer to draw the bar
                // glyph without the number).
                var elements: [LayoutElement] = []
                for staffIdx in staves.indices {
                    guard staffIdx < staffOrigins.count else { continue }
                    let staffY = staffOrigins[staffIdx].y
                    let staffCenterY = staffY + staffHeights[staffIdx] / 2
                    elements.append(.multiMeasureRest(
                        count: runLen,
                        origin: CGPoint(
                            x: um.contentWidth / 2, y: staffCenterY,
                        ),
                    ))
                    // A run that ends the system announces too. Pass 2
                    // has already applied the staff origins here, so the
                    // staff-local glyphs get the same shift the normal
                    // path applies during translation.
                    if let courtesy = trailingCourtesy,
                       um.measureIdx == announcingMeasureIdx
                    {
                        let yOffset = staffY - metrics.sp * 2
                        elements.append(contentsOf: courtesyElements(
                            courtesy,
                            staffIndex: staffIdx,
                            contentWidth: um.contentWidth,
                            clef: clefs[staffIdx],
                            lineGeometry: staffGeometries[staffIdx],
                            metrics: metrics,
                        ).map { translate(element: $0, dy: yOffset) })
                    }
                    // Right-edge barline mirrors normal measures so the
                    // system's visible separators stay continuous. Collapsed
                    // measures bypass placeMeasureElements, so we add it
                    // here directly. The subtype from the run's last source
                    // measure carries through (e.g. final / double barlines).
                    // The renderers stroke `origin.y ± halfHeight`, so
                    // anchor to staffCenterY, not the staff top.
                    // `staffCenterY` already equals the midpoint of
                    // `barLineSpanY` for every line count (both are 0
                    // for a one-line staff), so only the half-height
                    // needs the geometry.
                    let barSpan = staffGeometries[staffIdx]
                        .barLineSpanY(sp: metrics.sp)
                    elements.append(.barLine(
                        subtype: barSubtype,
                        origin: CGPoint(
                            x: um.contentWidth, y: staffCenterY,
                        ),
                        halfHeight: (barSpan.bottom - barSpan.top) / 2,
                    ))
                }
                let sourceMeasure = um.staff0Measure
                layoutMeasures.append(LayoutMeasure(
                    measureIndex: um.measureIdx,
                    origin: CGPoint(x: xCursor, y: 0),
                    width: um.width,
                    elements: elements,
                    markers: [],
                    jumps: [],
                    lineBreak: sourceMeasure?.lineBreak ?? false,
                    pageBreak: sourceMeasure?.pageBreak ?? false,
                    tickColumns: [:],
                    multiMeasureRest: runLen,
                ))
                xCursor += um.width
                continue
            }
            let w = um.width
            let measureIdx = um.measureIdx
            var aggregated: [LayoutElement] = []
            var aggregatedInvisible: [LayoutElement] = []
            var markers: [LayoutElement] = []
            var jumps: [LayoutElement] = []
            var dynamicExtents: [LayoutMeasure.DynamicExtent] = []
            for staffIdx in staves.indices {
                // Placement emits positions relative to "staff top
                // at sp*2" (see `staffMidY` inside
                // `placeMeasureElements`). Shift by the difference
                // so placement coords end up in system coords.
                let yOffset = staffOrigins[staffIdx].y
                    - metrics.sp * 2
                // Ledger lines are emitted here, the last point where
                // staff identity still exists (their count depends on
                // the staff's line count). Running after spacing keeps
                // `.ledgerLine` out of the width computation.
                let geometry = staffGeometries[staffIdx]
                if let els = um.perStaffElements[staffIdx] {
                    // Record dynamic spans BEFORE aggregation — after
                    // it, the staff each dynamic belongs to is gone.
                    // Only X is read, and `translate` moves Y only.
                    dynamicExtents.append(contentsOf: collectDynamicExtents(
                        in: els, staffIndex: staffIdx,
                        tickColumns: um.tickCols, metrics: metrics,
                    ))
                    let withLedgers = LedgerLinePass.insert(
                        into: els,
                        metrics: metrics,
                        firstStepAbove: geometry.firstLedgerStepAbove,
                        firstStepBelow: geometry.firstLedgerStepBelow,
                        invisibleNotes: false,
                    )
                    aggregated.append(contentsOf: withLedgers.map {
                        translate(element: $0, dy: yOffset)
                    })
                }
                // Hidden annotations get the same staff-local → system
                // translation so renderers can draw them at the right Y.
                if let invisible = um.perStaffInvisibleElements[staffIdx] {
                    // These are fully hidden CHORDS, whose notes normally
                    // still carry `isInvisible == false` — the renderers
                    // draw them through the ordinary chord path, so the
                    // VISIBLE subset is the one that gets ledgers here.
                    let withLedgers = LedgerLinePass.insert(
                        into: invisible,
                        metrics: metrics,
                        firstStepAbove: geometry.firstLedgerStepAbove,
                        firstStepBelow: geometry.firstLedgerStepBelow,
                        invisibleNotes: false,
                    )
                    aggregatedInvisible.append(contentsOf: withLedgers.map {
                        translate(element: $0, dy: yOffset)
                    })
                }
                // Ledgers of hidden NOTEHEADS inside a visible chord.
                // They used to be drawn inline in a 50 % group; routing
                // them through `invisibleElements` matches how every
                // other invisible element is handled, at the cost of
                // moving them above later ink in the same measure.
                if let els = um.perStaffElements[staffIdx],
                   context.options.showsInvisibleElements
                {
                    let hidden = LedgerLinePass.insert(
                        into: els,
                        metrics: metrics,
                        firstStepAbove: geometry.firstLedgerStepAbove,
                        firstStepBelow: geometry.firstLedgerStepBelow,
                        invisibleNotes: true,
                    ).filter { if case .ledgerLine = $0 { true } else { false } }
                    aggregatedInvisible.append(contentsOf: hidden.map {
                        translate(element: $0, dy: yOffset)
                    })
                }
                // Ledgers of hidden NOTEHEADS inside an already fully
                // hidden chord. These used to render at ~25 % opacity (a
                // 50 % group nested inside the invisible pass's own 50 %
                // context) before ledgers became sibling elements of the
                // chord's layer group; that nesting no longer exists, so
                // they now render at the same flat 50 % as every other
                // invisible element, matching MuseScore's single
                // `invisibleColor()`.
                if let invisible = um.perStaffInvisibleElements[staffIdx] {
                    let hidden = LedgerLinePass.insert(
                        into: invisible,
                        metrics: metrics,
                        firstStepAbove: geometry.firstLedgerStepAbove,
                        firstStepBelow: geometry.firstLedgerStepBelow,
                        invisibleNotes: true,
                    ).filter { if case .ledgerLine = $0 { true } else { false } }
                    aggregatedInvisible.append(contentsOf: hidden.map {
                        translate(element: $0, dy: yOffset)
                    })
                }
            }
            // Markers / jumps come from the first staff only — they
            // apply to the whole system at this measure, not per
            // staff. A piano grand staff repeats the same marker
            // on both staves in MSCX; we draw it once above the
            // top staff to match engraving convention.
            if let m = um.staff0Measure {
                let staffTopY = staffOrigins[0].y
                // Jump text hangs 1 sp below staff 0. It has to clear
                // the staff's INK, and noteheads keep occupying the
                // five-line reference band no matter how many lines are
                // drawn (`StaffLineGeometry.topStep`) — so on a
                // one-line staff, whose drawn height is 0, the jump
                // would land 1 sp above `step` 0 and collide with the
                // notes. Take whichever band is taller: the drawn staff
                // (for counts above five) or the reference one.
                let staffBottomY = staffTopY + max(
                    staffHeights.first ?? 0, metrics.staffHeight,
                )
                for marker in m.markers {
                    let labelText = marker.text.isEmpty
                        ? marker.label : marker.text
                    markers.append(.marker(
                        kind: marker.kind,
                        text: labelText,
                        origin: CGPoint(
                            x: 4, y: staffTopY - metrics.sp,
                        ),
                    ))
                }
                for jump in m.jumps {
                    jumps.append(.jump(
                        text: jump.text,
                        origin: CGPoint(
                            x: w - metrics.sp * 4,
                            y: staffBottomY + metrics.sp,
                        ),
                    ))
                }
            }
            // Surface the source measure's break flags so the
            // pagination phase (page break → close page) and the
            // on-screen indicator overlay (icons at the measure's
            // top-right) can consult them without re-walking
            // `score.allStaves`.
            let sourceMeasure = staves.first
                .flatMap { $0.measures.indices.contains(measureIdx)
                    ? $0.measures[measureIdx]
                    : nil
                }
            layoutMeasures.append(LayoutMeasure(
                measureIndex: measureIdx,
                origin: CGPoint(x: xCursor, y: 0),
                width: w,
                elements: aggregated,
                markers: markers,
                jumps: jumps,
                lineBreak: sourceMeasure?.lineBreak ?? false,
                pageBreak: sourceMeasure?.pageBreak ?? false,
                tickColumns: um.tickCols,
                invisibleElements: aggregatedInvisible,
                chordNorthByTick: buildChordNorthByTick(
                    from: aggregated, tickColumns: um.tickCols,
                    sp: metrics.sp,
                ),
                dynamicExtents: dynamicExtents,
            ))
            xCursor += w
        }

        // Baseline height: last staff's bottom + bottomPad.
        let lastStaffBottom = (staffOrigins.last?.y ?? topPad)
            + (staffHeights.last ?? metrics.staffHeight)
        let baselineHeight = lastStaffBottom + bottomPad

        // Extend to fit the actual bounding box of emitted elements so
        // nothing clips when e.g. a note lands on the 5th ledger line
        // above the top staff or a dynamic text hangs farther below the
        // bottom staff than the baseline allowed.
        // Spanner segments left `layoutMeasures` above, so they have to
        // be handed to the bbox separately — otherwise a hairpin the
        // skyline pushed below the last staff would not extend the
        // system that has to contain it.
        let bbox = elementYBounds(
            in: layoutMeasures,
            extraElements: systemSpanners,
            metrics: metrics,
        )
        let bottomSlack = max(0, bbox.max - baselineHeight) + metrics.sp * 2
        let totalHeight = baselineHeight + bottomSlack

        // Content above y=0 (e.g. a tempo glyph above staff 0 when the
        // existing topPad isn't quite enough) would clip against the
        // document's top edge. If we see it, shift every element down
        // and enlarge the system so the whole bounding box is visible.
        let topShift = max(0, -bbox.min + metrics.sp * 2)
        let adjustedMeasures = topShift > 0
            ? layoutMeasures.map { shiftMeasure($0, dy: topShift) }
            : layoutMeasures
        let adjustedStaffOrigins = topShift > 0
            ? staffOrigins.map { CGPoint(x: $0.x, y: $0.y + topShift) }
            : staffOrigins
        let adjustedSpanners = topShift > 0
            ? systemSpanners.map { translate(element: $0, dy: topShift) }
            : systemSpanners
        let adjustedLabels = topShift > 0
            ? labels.map {
                LayoutPartLabel(
                    text: $0.text,
                    origin: CGPoint(x: $0.origin.x, y: $0.origin.y + topShift),
                )
            }
            : labels
        let adjustedBrackets = topShift > 0
            ? brackets.map {
                LayoutBracket(
                    type: $0.type,
                    topY: $0.topY + topShift,
                    bottomY: $0.bottomY + topShift,
                    column: $0.column,
                    staffCount: $0.staffCount,
                )
            }
            : brackets

        // Hand the (possibly mutated) clef / key state back to the
        // caller so the next system continues from where this one
        // ended.
        activeClefs = clefs
        activeKeys = keys

        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight + topShift),
            measures: adjustedMeasures,
            staffOrigins: adjustedStaffOrigins,
            staffAddresses: allStaves.map(\.address),
            staffGeometries: staffGeometries,
            partLabels: adjustedLabels,
            brackets: adjustedBrackets,
            spanners: adjustedSpanners,
            sp: metrics.sp,
            showsInvisibleElements: context.options.showsInvisibleElements,
        )
    }

    /// Build a tick → minimum (highest) notehead TOP-EDGE Y map for vibrato
    /// autoplace. Scans `elements` for `.chord` entries, reverse-maps
    /// `stemOrigin.x` to a tick via `tickColumns`, and records the minimum
    /// note top-edge Y (center − halfNoteheadHeight; smallest = highest in
    /// Y-down coords) for each tick. Y values are system-level (already
    /// translated by the per-staff Y offset). Empty when there are no chords
    /// or `tickColumns` is empty.
    ///
    /// **Why top-edge, not center:** MuseScore's skyline north is the
    /// topmost ink edge of each element. A standard SMuFL notehead is ~1 sp
    /// tall so its top edge is `center.y − 0.5 sp`. Using the center
    /// (old behaviour) lost 0.5 sp of vertical clearance, causing the
    /// vibrato to render too close to high notes.
    /// Measure-local ink spans of the dynamics in one staff's element
    /// buffer, each tagged with the tick it is anchored at.
    ///
    /// The tick is recovered from the X the dynamic was placed at.
    /// `placeMeasureElements` anchors a dynamic at `timedX(tick) − sp`
    /// (the 1 sp left shift that keeps the label off the notehead), so
    /// the anchor column is `origin.x + sp` and an exact hit in
    /// `tickColumns` is the normal case. A dynamic that precedes the
    /// measure's first timed element is placed off the header's
    /// `contentStartX` instead, landing left of every column — it
    /// belongs to the first tick at or after its anchor.
    static func collectDynamicExtents(
        in elements: [LayoutElement],
        staffIndex: Int,
        tickColumns: [Int: CGFloat],
        metrics: StaffMetrics,
    ) -> [LayoutMeasure.DynamicExtent] {
        guard !tickColumns.isEmpty else { return [] }
        var out: [LayoutMeasure.DynamicExtent] = []
        for element in elements {
            guard case let .textMark(kind, _, origin) = element,
                  kind == .dynamic,
                  let tick = dynamicTick(
                      anchorX: origin.x + metrics.sp,
                      tickColumns: tickColumns,
                  ),
                  let shape = LayoutElementShape.shape(
                      for: element, id: 0, xOffset: 0, metrics: metrics,
                  ),
                  let minX = shape.rects.map(\.rect.minX).min(),
                  let maxX = shape.rects.map(\.rect.maxX).max()
            else { continue }
            out.append(LayoutMeasure.DynamicExtent(
                staffIndex: staffIndex, tick: tick,
                minX: minX, maxX: maxX,
            ))
        }
        return out
    }

    private static func dynamicTick(
        anchorX: CGFloat, tickColumns: [Int: CGFloat],
    ) -> Int? {
        for (tick, columnX) in tickColumns
            where abs(columnX - anchorX) < 0.01
        {
            return tick
        }
        return tickColumns
            .filter { $0.value >= anchorX }
            .min { $0.value < $1.value }?
            .key
    }

    private static func buildChordNorthByTick(
        from elements: [LayoutElement], tickColumns: [Int: CGFloat],
        sp: CGFloat,
    ) -> [Int: CGFloat] {
        guard !tickColumns.isEmpty else { return [:] }
        // Reverse: measure-local X → tick. Two chords at the same X
        // (same tick, different voices) both contribute to the same
        // tick's minimum.
        let xToTick: [CGFloat: Int] = Dictionary(
            tickColumns.map { ($0.value, $0.key) },
            uniquingKeysWith: { _, b in b },
        )
        let halfNoteheadHeight = sp * 0.5
        var map: [Int: CGFloat] = [:]
        for element in elements {
            guard case let .chord(notes, _, _, stemOrigin, _, _, _, _, _, _, _) = element,
                  !notes.isEmpty,
                  let tick = xToTick[stemOrigin.x]
            else { continue }
            // Note TOP = center.y − halfNoteheadHeight (Y-down: smaller = higher).
            let centerY = notes.map(\.origin.y).min() ?? stemOrigin.y
            let topY = centerY - halfNoteheadHeight
            map[tick] = min(map[tick] ?? .greatestFiniteMagnitude, topY)
        }
        return map
    }
}
