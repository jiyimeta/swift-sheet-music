// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    // MARK: - Per-system layout

    static func buildSystem( // swiftlint:disable:this function_body_length
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        activeClefs: inout [NotatedClef],
        activeKeys: inout [Int],
        context: RenderContext,
    ) -> LayoutSystem {
        let metrics = context.metrics
        let allStaves = context.score.allStaves
        let staves = allStaves.map(\.staff)
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
        struct UntranslatedMeasure {
            let measureIdx: Int
            let width: CGFloat
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
        // Pre-compute effective measure durations once per staff so
        // `placeMeasureElements` receives the prevailing time signature
        // (carried forward across measures that contain no explicit
        // `<TimeSignature>` element) rather than deriving a local-scan-
        // only fallback. Indexed as `staffMeasureDurations[staffIdx]`.
        let staffMeasureDurations: [[Fraction]] = staves.map {
            $0.measures.effectiveMeasureDurations()
        }
        // Cross-staff duration table for `tickColumns`, computed once
        // per system build rather than re-derived per measure (see
        // `effectiveMeasureDurationsAcrossStaves`).
        let sharedMeasureDurations = effectiveMeasureDurationsAcrossStaves(
            staves: staves,
        )
        var untranslated: [UntranslatedMeasure] = []
        var clefs = activeClefs
        var keys = activeKeys
        let plan = context.multiMeasureRestPlan
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
                    perStaffElements: [:],
                    perStaffInvisibleElements: [:],
                    staff0Measure: staff0Measure,
                    tickCols: [:],
                    multiMeasureRestCount: runLen,
                ))
                continue
            }
            let w = widths[j]
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
            let tickCols = tickColumns(
                staves: staves,
                measureIdx: measureIdx,
                metrics: metrics,
                headerSchedule: schedule,
                width: w,
                division: context.score.division,
                measureDuration: measureDuration(
                    sharedMeasureDurations, at: measureIdx,
                ),
            )
            var perStaff: [Int: [LayoutElement]] = [:]
            var perStaffInvisible: [Int: [LayoutElement]] = [:]
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
                let coversBelowStaffSpanner = context
                    .belowStaffSpannerCoverage[staffIdx]?
                    .contains(measureIdx) ?? false
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
                let measDuration: Fraction = {
                    let durations = staffMeasureDurations[staffIdx]
                    return measureIdx < durations.count
                        ? durations[measureIdx]
                        : Fraction(numerator: 4, denominator: 4)
                }()
                let placementInputs = LayoutCache.PlacementInputs(
                    measure: m,
                    width: w,
                    metricsSp: metrics.sp,
                    activeClef: clefs[staffIdx],
                    activeKey: keys[staffIdx],
                    initialClefRawType: synthClef,
                    initialKeyForSynth: synthKey,
                    headerSchedule: schedule,
                    tickColumns: tickCols,
                    division: context.score.division,
                    drumLineMap: drumMap,
                    isLastMeasure: lastMeasure,
                    isFirstSystem: isFirstSystem,
                    incomingMelismas: incomingMelismas,
                    effectiveMelismaTicks: context.effectiveMelismaTicks,
                    graceNoteMag: context.options.graceNoteMag,
                    coversBelowStaffSpanner: coversBelowStaffSpanner,
                    systemElements: systemElementsForStaff,
                    showsInvisibleElements: context.options.showsInvisibleElements,
                    measureDuration: measDuration,
                )
                let els: [LayoutElement]
                let invisibleEls: [LayoutElement]
                let newClef: NotatedClef
                let newKey: Int
                if let cached = context.cache?
                    .entries[measureIdx]?.placements[staffIdx],
                    cached.inputs == placementInputs
                {
                    els = cached.elements
                    invisibleEls = cached.invisibleElements
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
                        initialClefRawType: synthClef,
                        initialKeyForSynth: synthKey,
                        headerSchedule: schedule,
                        tickColumns: tickCols,
                        division: context.score.division,
                        measureDuration: measDuration,
                        drumLineMap: drumMap,
                        isLastMeasure: lastMeasure,
                        isFirstSystem: isFirstSystem,
                        incomingMelismas: incomingMelismas,
                        effectiveMelismaTicks: context.effectiveMelismaTicks,
                        coversBelowStaffSpanner: coversBelowStaffSpanner,
                        systemElements: systemElementsForStaff,
                    )
                    els = result.elements
                    invisibleEls = result.invisibleElements
                    newClef = result.clef
                    newKey = result.key
                    context.cache?.placementMisses += 1
                    if var entry = context.cache?.entries[measureIdx] {
                        entry.placements[staffIdx] = LayoutCache
                            .StaffPlacement(
                                inputs: placementInputs,
                                elements: els,
                                invisibleElements: invisibleEls,
                                newClef: newClef,
                                newKey: newKey,
                            )
                        context.cache?.entries[measureIdx] = entry
                    }
                }
                clefs[staffIdx] = newClef
                keys[staffIdx] = newKey
                perStaff[staffIdx] = els
                if !invisibleEls.isEmpty {
                    perStaffInvisible[staffIdx] = invisibleEls
                }
            }
            // Measure number at every system head — TOP STAFF ONLY.
            // Engraving convention places a single number above the
            // topmost staff at the start of each system. Irregular
            // measures (anacrusis) suppress the label.
            //
            // Emitted HERE rather than in pass 2 so the element sits in
            // the per-staff buffer the skyline autoplace pass operates
            // on. Staff-local Y: the staff top is at `sp * 2`, so
            // `sp * 2 - sp * 1.5` reproduces pass 2's
            // `staffOrigins[0].y - sp * 1.5` after translation.
            if untranslated.isEmpty, !staves.isEmpty,
               let displayed = context.score.displayedMeasureNumber(
                   at: measureIdx,
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
                width: w,
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
        do {
            var xCursor: CGFloat = partLabelWidth
            var xOffsets: [CGFloat] = []
            for um in untranslated {
                xOffsets.append(xCursor)
                xCursor += um.width
            }
            let staffMidYLocal = metrics.sp * 2 + metrics.staffHeight / 2
            for staffIdx in 0 ..< staves.count {
                var perStaff: [[LayoutElement]] = untranslated.map {
                    $0.perStaffElements[staffIdx] ?? []
                }
                SkylineAutoplacePass.run(
                    measures: &perStaff,
                    xOffsets: xOffsets,
                    systemRightX: xCursor,
                    staffMidY: staffMidYLocal,
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
        let staffTopLocal: CGFloat = metrics.sp * 2
        let staffBottomLocal: CGFloat = staffTopLocal
            + metrics.staffHeight
        var staffMinY = Array(
            repeating: CGFloat.infinity, count: staves.count,
        )
        var staffMaxY = Array(
            repeating: -CGFloat.infinity, count: staves.count,
        )
        for um in untranslated {
            for (staffIdx, els) in um.perStaffElements {
                for el in els {
                    for y in elementYPoints(el) {
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
                ? max(0, staffMaxY[idx] - staffBottomLocal)
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
                currentY += metrics.staffHeight
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
                    let bottomY = staffOrigins[endFlat].y
                        + metrics.staffHeight
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
            let bottomY = staffOrigins[lastFlat].y + metrics.staffHeight
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
                if let firstStaff = staves.first,
                   lastMeasureIdx < firstStaff.measures.count
                {
                    let lastMeasure = firstStaff.measures[lastMeasureIdx]
                    for voice in lastMeasure.voices {
                        for el in voice.elements {
                            if case let .barLine(b) = el {
                                barSubtype = b.subtype
                            }
                        }
                    }
                }
                if barSubtype == nil, isLastMeasureOfScore {
                    barSubtype = "end"
                }

                // Emit one H-bar + one barline per staff.
                // Count text appears only above the top staff (count == 0
                // on lower staves instructs the renderer to draw the bar
                // glyph without the number).
                var elements: [LayoutElement] = []
                for staffIdx in staves.indices {
                    guard staffIdx < staffOrigins.count else { continue }
                    let staffY = staffOrigins[staffIdx].y
                    let staffCenterY = staffY + metrics.staffHeight / 2
                    elements.append(.multiMeasureRest(
                        count: runLen,
                        origin: CGPoint(x: um.width / 2, y: staffCenterY),
                    ))
                    // Right-edge barline mirrors normal measures so the
                    // system's visible separators stay continuous. Collapsed
                    // measures bypass placeMeasureElements, so we add it
                    // here directly. The subtype from the run's last source
                    // measure carries through (e.g. final / double barlines).
                    // drawBarLine treats origin.y as the staff's vertical
                    // center (line spans origin.y ± 2 sp), so anchor to
                    // staffCenterY, not the staff top.
                    elements.append(.barLine(
                        subtype: barSubtype,
                        origin: CGPoint(x: um.width, y: staffCenterY),
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
                if let els = um.perStaffElements[staffIdx] {
                    // Record dynamic spans BEFORE aggregation — after
                    // it, the staff each dynamic belongs to is gone.
                    // Only X is read, and `translate` moves Y only.
                    dynamicExtents.append(contentsOf: collectDynamicExtents(
                        in: els, staffIndex: staffIdx,
                        tickColumns: um.tickCols, metrics: metrics,
                    ))
                    aggregated.append(contentsOf: els.map {
                        translate(element: $0, dy: yOffset)
                    })
                }
                // Hidden annotations get the same staff-local → system
                // translation so renderers can draw them at the right Y.
                if let invisible = um.perStaffInvisibleElements[staffIdx] {
                    aggregatedInvisible.append(contentsOf: invisible.map {
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
                let staffBottomY = staffTopY + metrics.staffHeight
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
            + metrics.staffHeight
        let baselineHeight = lastStaffBottom + bottomPad

        // Extend to fit the actual bounding box of emitted elements so
        // nothing clips when e.g. a note lands on the 5th ledger line
        // above the top staff or a dynamic text hangs farther below the
        // bottom staff than the baseline allowed.
        let bbox = elementYBounds(
            in: layoutMeasures,
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
            partLabels: adjustedLabels,
            brackets: adjustedBrackets,
            spanners: [],
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
    private static func collectDynamicExtents(
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
