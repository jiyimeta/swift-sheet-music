import CoreGraphics
import SheetMusicCore

/// Pure function: `Score` → `LayoutDocument`.
///
/// v1 is a single-pass engine with simple heuristics. No caching, no
/// mutation, no back-pointers. Safe to re-run on every option change.
///
/// The enum is split across extensions for readability:
/// - `LayoutEngine+Spacing.swift`    — measure width calculations.
/// - `LayoutEngine+Placement.swift`  — per-measure element placement
///   (`placeMeasureElements`), glissando, beaming pass.
/// - `LayoutEngine+Beaming.swift`    — `beamGroups` + helpers.
/// - `LayoutEngine+Spanners.swift`   — anchor collect + attach pass.
/// - `LayoutEngine+Ties.swift`       — tie pair resolve + attach.
@available(macOS 15.0, iOS 16.0, *)
public enum LayoutEngine {
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat
    ) -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let effectiveMelismaTicks = computeEffectiveMelismaTicks(
            score: score, division: score.division)
        let melismas = computeMelismaContinuations(
            score: score, division: score.division,
            effectiveTicks: effectiveMelismaTicks)
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth,
            melismaContinuations: melismas,
            effectiveMelismaTicks: effectiveMelismaTicks
        )
        let packedSystems = packSystems(context: context)
        // Title block at the top of the document. Built first so we
        // know how much vertical space to leave above the first
        // system.
        let titleFrame: LayoutTitleFrame? = {
            guard options.includeTitleFrame, let src = score.titleFrame
            else { return nil }
            return buildTitleFrame(
                source: src,
                metrics: metrics,
                docWidth: max(availableWidth,
                    packedSystems.reduce(CGFloat(0)) { acc, s in
                        max(acc, s.origin.x + s.size.width)
                    }))
        }()
        let yShift = titleFrame?.height ?? 0
        let systems = yShift > 0
            ? packedSystems.map { shift($0, byY: yShift) }
            : packedSystems
        // Use the actual rendered system extent — not `availableWidth`,
        // which may be larger than the content needs.
        let totalWidth = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.x + system.size.width)
        }
        let totalHeight = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.y + system.size.height)
        }
        let anchors = collectSpanners(score: score)
        let systemsWithSpanners = attachSpanners(
            to: systems,
            anchors: anchors,
            score: score,
            metrics: metrics
        )
        // Add a small right margin so the last barline doesn't
        // touch the canvas edge.
        let docWidth = totalWidth + metrics.sp * 2
        let firstPass = LayoutDocument(
            size: CGSize(width: docWidth, height: totalHeight),
            systems: systemsWithSpanners,
            metrics: metrics,
            titleFrame: titleFrame
        )
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTies(
            to: systemsWithSpanners, pairs: ties, metrics: metrics)
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithTies,
            metrics: metrics,
            titleFrame: titleFrame
        )
    }

    private static func shift(
        _ system: LayoutSystem, byY dy: CGFloat
    ) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(
                x: system.origin.x, y: system.origin.y + dy),
            size: system.size,
            measures: system.measures,
            staffOrigins: system.staffOrigins,
            partLabels: system.partLabels,
            spanners: system.spanners)
    }

    private static func buildTitleFrame(
        source: ScoreFrame,
        metrics: StaffMetrics,
        docWidth: CGFloat
    ) -> LayoutTitleFrame {
        // MuseScore's `<height>` is in spatium units. Clamp to a
        // tiny minimum so a malformed VBox doesn't drop text on top
        // of the first staff, but otherwise honour what the score
        // declared (and any `<offset>` overrides on individual
        // texts).
        let frameHeight = max(
            metrics.sp * 4,
            source.heightSp * metrics.sp)
        let center = docWidth / 2

        // MuseScore stores offsets for the title-block styles in
        // millimetres (`OffsetType::ABS` — see `styledef.cpp`).
        // Conversion to typographic points: 72 pt ÷ 25.4 mm.  We use
        // the same conversion for both the per-text override
        // (`<offset>` in `.mscx`) and the styledef defaults (e.g.
        // `subTitleOffset = PointF(0, 10)` ⇒ 10 mm below VBox top).
        let mmToPt: CGFloat = 72.0 / 25.4

        var laidOut: [LayoutFrameText] = []
        for (idx, t) in source.texts.enumerated() {
            // Defaults sourced from MuseScore's
            // `engraving/style/styledef.cpp`:
            //   Title    — Align(HCENTER, TOP),    offset (0,  0) mm, font 22pt
            //   Subtitle — Align(HCENTER, TOP),    offset (0, 10) mm, font 14pt
            //   Composer — Align(RIGHT,   BOTTOM), offset (0,  0) mm, font 10pt
            //   Lyricist — Align(LEFT,    BOTTOM), offset (0,  0) mm, font 10pt
            // All four are `FontStyle::Normal` (no bold / italic).
            // `<Text>` inline `<b>` / `<font>` markup is stripped
            // at parse time.
            let fontSize: CGFloat
            let baseY: CGFloat
            let baseX: CGFloat
            let anchor: LayoutFrameText.Anchor
            switch t.style {
            case .title:
                fontSize = 22
                baseY = 0
                baseX = center
                anchor = .top
            case .subtitle:
                fontSize = 14
                baseY = 10 * mmToPt
                baseX = center
                anchor = .top
            case .composer:
                fontSize = 10
                baseY = frameHeight
                baseX = docWidth
                anchor = .bottomTrailing
            case .lyricist:
                fontSize = 10
                baseY = frameHeight
                baseX = 0
                anchor = .bottomLeading
            case .other:
                fontSize = 10
                baseY = 10 * mmToPt
                    + CGFloat(idx) * 4 * mmToPt
                baseX = center
                anchor = .top
            }
            let dx = (t.offsetMm?.x ?? 0) * mmToPt
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            laidOut.append(LayoutFrameText(
                text: t.text,
                style: t.style,
                position: CGPoint(x: baseX + dx, y: baseY + dy),
                fontSize: fontSize,
                anchor: anchor))
        }
        return LayoutTitleFrame(
            height: frameHeight, texts: laidOut)
    }

    // MARK: - Context

    struct RenderContext {
        let score: Score
        let options: ScoreViewOptions
        let metrics: StaffMetrics
        let availableWidth: CGFloat
        /// Per-(staff, measure) melisma continuation lines.
        /// `melismaContinuations[staffIdx][measureIdx]` lists the
        /// melismas that extend INTO this measure from an earlier
        /// measure. The measure that owns the anchor `<Lyrics>` is
        /// handled by the per-chord `emitMelismaLine` path and is
        /// not included here.
        let melismaContinuations: [[[MelismaContinuation]]]
        /// Per-lyric effective melisma duration (in ticks) that
        /// accounts for tied-chain continuations past the anchor
        /// note. Used by `placeMeasureElements` so that the
        /// "melisma?" check is consistent with the continuation
        /// plan from `computeMelismaContinuations`.
        let effectiveMelismaTicks: [MelismaLyricKey: Int]
    }

    // MARK: - System packing

    static func packSystems(
        context: RenderContext
    ) -> [LayoutSystem] {
        let stavesCount = context.score.staves.count
        guard stavesCount > 0,
              let firstStaff = context.score.staves.first,
              !firstStaff.measures.isEmpty else {
            return []
        }

        let measureCount = firstStaff.measures.count
        // Per-measure minimum width = max across staves so that the
        // widest staff's content fits at this index.
        let minWidths: [CGFloat] = (0..<measureCount).map { i in
            context.score.staves.map { staff in
                i < staff.measures.count
                    ? minimumMeasureWidth(
                        measure: staff.measures[i],
                        metrics: context.metrics)
                    : 0
            }.max() ?? 0
        }

        // Clef state persists ACROSS systems: engraving convention
        // redraws the currently active clef at the start of every
        // new system (line break).  Without this persistence,
        // continuation systems would either omit the clef or restore
        // an outdated default, losing any mid-piece clef changes.
        var activeClefs: [NotatedClef] = defaultClefRawTypes(
            staves: context.score.staves,
            parts: context.score.parts
        ).map { NotatedClef(rawType: $0) }

        // Key signatures follow the same engraving rule: redraw the
        // currently active key at the start of every system.  Core
        // storage is `concertKey` — positive = sharps, negative =
        // flats, 0 = C major (drawn as nothing).
        var activeKeys: [Int] = Array(
            repeating: 0,
            count: context.score.staves.count)

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
        let firstSystemLabelW = labelWidth(
            score: context.score,
            metrics: context.metrics,
            useLong: true)
        let continuationLabelW = labelWidth(
            score: context.score,
            metrics: context.metrics,
            useLong: false)
        while cursor < measureCount {
            // Part-label width depends on whether this is the first
            // system — the first shows long names, subsequent short.
            let labelW: CGFloat = isFirstSystem
                ? firstSystemLabelW : continuationLabelW
            // The CONTENT area starts after the label; measures must
            // fit within availableWidth − labelW.
            let contentAvail = context.availableWidth - labelW
            var widthSoFar: CGFloat = 0
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
                staves: context.score.staves,
                measureIdx: systemStart,
                activeKeys: activeKeys,
                metrics: context.metrics
            )
            // Targeted measures-per-system across the next forced
            // line-break boundary (or score end). MuseScore's
            // system layout balances measures evenly between
            // breaks rather than greedily filling the first system
            // — see
            // `engraving/rendering/score/systemlayout.cpp` and
            // `Sid::lastSystemFillLimit`. Without this lookahead,
            // a span of 8 measures with sparse content packs as
            // 6 + 2 instead of MuseScore's 4 + 4.
            let balancedTarget = context.options.wrapToViewWidth
                ? balancedMeasuresPerSystem(
                    fromIndex: systemStart,
                    measureCount: measureCount,
                    minWidths: minWidths,
                    firstHeaderBoost: firstHeaderBoost,
                    contentAvail: contentAvail,
                    staves: context.score.staves)
                : Int.max
            // MuseScore-style natural-stretch target. Systems
            // whose minimum-width content fills less than
            // `1 / naturalStretch` of the available width are
            // packed further; once a candidate would stretch
            // less than that ratio we close the system. Without
            // this knob, sparse content (whole rests, half notes)
            // packs 8-9 measures per system at a 1.0x ratio,
            // producing dense pages MuseScore would have split
            // into 4-measure systems for visual breathing. 1.5
            // is the ratio at which MuseScore's mostly-4-measure
            // wraps emerge on dense lyric content; loosening
            // further re-introduces 5-6 measure systems.
            let naturalStretch: CGFloat = 1.5
            let naturalAvail = contentAvail / naturalStretch
            while cursor < measureCount {
                let baseW = minWidths[cursor]
                let w = cursor == systemStart
                    ? baseW + firstHeaderBoost
                    : baseW
                // Hard ceiling — never let a system overflow the
                // page horizontally.
                if context.options.wrapToViewWidth
                    && widthSoFar + w > contentAvail
                    && cursor > systemStart {
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
                    && widthSoFar + w > naturalAvail {
                    break
                }
                if context.options.wrapToViewWidth
                    && cursor - systemStart >= balancedTarget {
                    break
                }
                widthSoFar += w
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
                        staves: context.score.staves) {
                    break
                }
            }
            var widthsSlice = Array(minWidths[systemStart..<cursor])
            if !widthsSlice.isEmpty {
                widthsSlice[0] += firstHeaderBoost
            }
            let stretched = stretchWidths(
                widths: widthsSlice,
                availableWidth: contentAvail,
                shouldStretch: context.options.wrapToViewWidth
            )
            let system = buildSystem(
                measureRange: systemStart..<cursor,
                widths: stretched,
                systemOriginY: currentY,
                isFirstSystem: isFirstSystem,
                activeClefs: &activeClefs,
                activeKeys: &activeKeys,
                context: context
            )
            currentY += system.size.height + context.options.systemGap
            systems.append(system)
            isFirstSystem = false
        }
        return systems
    }

    /// Resolve each staff's starting-of-score default clef from the
    /// part's declarations.  Mirrors the logic used previously inside
    /// `buildSystem`; factored out so `packSystems` can initialise the
    /// clef carry-over state before entering the system loop.
    static func defaultClefRawTypes(
        staves: [StaffContent],
        parts: [Part]
    ) -> [String] {
        staves.enumerated().map { idx, _ in
            let part = idx < parts.count ? parts[idx] : nil
            let decl = part?.staffDeclarations.first
            if let declared = decl?.defaultClefType {
                return declared
            }
            if decl?.group == "percussion" { return "PERC" }
            return "G"
        }
    }

    static func stretchWidths(
        widths: [CGFloat],
        availableWidth: CGFloat,
        shouldStretch: Bool
    ) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard shouldStretch, total > 0, availableWidth > total else {
            return widths
        }
        let ratio = availableWidth / total
        return widths.map { $0 * ratio }
    }

    // MARK: - Per-system layout

    static func buildSystem(
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        activeClefs: inout [NotatedClef],
        activeKeys: inout [Int],
        context: RenderContext
    ) -> LayoutSystem {
        let metrics = context.metrics
        let staves = context.score.staves
        let partLabelWidth: CGFloat = labelWidth(
            score: context.score,
            metrics: metrics,
            useLong: isFirstSystem)

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
            let staff0Measure: Measure?
        }
        var untranslated: [UntranslatedMeasure] = []
        var clefs = activeClefs
        var keys = activeKeys
        for (j, measureIdx) in measureRange.enumerated() {
            let w = widths[j]
            let synthesizeClefHere = j == 0
            let synthesizeKeySigHere = j == 0
            let schedule = computeHeaderSchedule(
                measureIdx: measureIdx,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: synthesizeClefHere,
                synthesizeKeySigForAllStaves: synthesizeKeySigHere,
                activeKeys: keys
            )
            let tickCols = tickColumns(
                staves: staves,
                measureIdx: measureIdx,
                metrics: metrics,
                headerSchedule: schedule,
                width: w,
                division: context.score.division
            )
            var perStaff: [Int: [LayoutElement]] = [:]
            for (staffIdx, staff) in staves.enumerated() {
                guard measureIdx < staff.measures.count else { continue }
                let m = staff.measures[measureIdx]
                let synthClef: String? = synthesizeClefHere
                    ? clefs[staffIdx].rawType
                    : nil
                let synthKey: Int? = synthesizeKeySigHere
                    ? keys[staffIdx]
                    : nil
                let part = staffIdx < context.score.parts.count
                    ? context.score.parts[staffIdx] : nil
                let drumMap: [Int: Int]? =
                    part?.instrument.useDrumset == true
                        ? part?.instrument.drumLineMap
                        : nil
                let totalMeasures = staves.first?.measures.count ?? 0
                let lastMeasure = measureIdx == totalMeasures - 1
                let incomingMelismas = context.melismaContinuations
                    .indices.contains(staffIdx)
                    && context.melismaContinuations[staffIdx]
                        .indices.contains(measureIdx)
                    ? context.melismaContinuations[staffIdx][measureIdx]
                    : []
                let (els, newClef, newKey) = placeMeasureElements(
                    measure: m,
                    staffIndex: staffIdx,
                    measureIndex: measureIdx,
                    width: w,
                    metrics: metrics,
                    activeClef: clefs[staffIdx],
                    activeKey: keys[staffIdx],
                    initialClefRawType: synthClef,
                    initialKeyForSynth: synthKey,
                    headerSchedule: schedule,
                    tickColumns: tickCols,
                    division: context.score.division,
                    drumLineMap: drumMap,
                    isLastMeasure: lastMeasure,
                    incomingMelismas: incomingMelismas,
                    effectiveMelismaTicks: context.effectiveMelismaTicks
                )
                clefs[staffIdx] = newClef
                keys[staffIdx] = newKey
                perStaff[staffIdx] = els
            }
            let staff0Measure: Measure? = measureIdx
                < (staves.first?.measures.count ?? 0)
                ? staves.first?.measures[measureIdx]
                : nil
            untranslated.append(UntranslatedMeasure(
                measureIdx: measureIdx,
                width: w,
                perStaffElements: perStaff,
                staff0Measure: staff0Measure))
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
        for staffIdx in 0..<staves.count {
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
                       p.y < minY {
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
                where baseY < systemTargetY {
                let dy = systemTargetY - baseY
                if var els = untranslated[mIdx]
                    .perStaffElements[staffIdx] {
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
            repeating: CGFloat.infinity, count: staves.count)
        var staffMaxY = Array(
            repeating: -CGFloat.infinity, count: staves.count)
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
        let staffTopPads: [CGFloat] = staves.enumerated().map { idx, _ in
            let topOverflow: CGFloat = staffMinY[idx].isFinite
                ? max(0, staffTopLocal - staffMinY[idx]
                      + metrics.sp * 0.5)
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
                        if case .chord(let c) = el {
                            let nonEmpty = c.lyrics.filter {
                                !$0.text.isEmpty
                            }.count
                            maxLyricsVerses = max(
                                maxLyricsVerses, nonEmpty)
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
        for idx in 0..<staves.count {
            currentY += staffTopPads[idx]
            staffOrigins.append(CGPoint(
                x: partLabelWidth, y: currentY))
            if idx < staves.count - 1 {
                currentY += metrics.staffHeight
                    + staffBottomPads[idx] + minGap
            }
        }

        // Per-staff labels. Stage 5 assumes staves align 1:1 with parts;
        // multi-staff-per-part (piano grand staff) is handled the same
        // way for now — each staff gets its own label.
        let labels: [LayoutPartLabel] = staves.enumerated().map { idx, _ in
            let part = idx < context.score.parts.count
                ? context.score.parts[idx] : nil
            let text: String
            if isFirstSystem {
                text = part?.trackName
                    ?? part?.instrument.longName
                    ?? ""
            } else {
                text = part?.instrument.shortName
                    ?? part?.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
            let y = staffOrigins[idx].y + metrics.staffHeight / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: y)
            )
        }

        // --- Pass 2: translate elements with adjusted origins ---
        var layoutMeasures: [LayoutMeasure] = []
        var xCursor: CGFloat = partLabelWidth
        for (j, um) in untranslated.enumerated() {
            let w = um.width
            let measureIdx = um.measureIdx
            var aggregated: [LayoutElement] = []
            var markers: [LayoutElement] = []
            var jumps: [LayoutElement] = []
            for (staffIdx, _) in staves.enumerated() {
                guard let els = um.perStaffElements[staffIdx]
                else { continue }
                // Placement emits positions relative to "staff top
                // at sp*2" (see `staffMidY` inside
                // `placeMeasureElements`). Shift by the difference
                // so placement coords end up in system coords.
                let yOffset = staffOrigins[staffIdx].y
                    - metrics.sp * 2
                aggregated.append(contentsOf: els.map {
                    translate(element: $0, dy: yOffset)
                })
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
                            x: 4, y: staffTopY - metrics.sp)
                    ))
                }
                for jump in m.jumps {
                    jumps.append(.jump(
                        text: jump.text,
                        origin: CGPoint(
                            x: w - metrics.sp * 4,
                            y: staffBottomY + metrics.sp
                        )
                    ))
                }
            }
            // Measure number at every system head — TOP STAFF
            // ONLY. Engraving convention places a single number
            // above the topmost staff at the start of each system.
            if j == 0, !staves.isEmpty {
                let staffTopY = staffOrigins[0].y
                markers.append(.measureNumber(
                    text: "\(measureIdx + 1)",
                    origin: CGPoint(
                        x: -metrics.sp * 0.5,
                        y: staffTopY - metrics.sp * 1.5)
                ))
            }
            // Surface the source measure's break flags so the
            // pagination phase (page break → close page) and the
            // on-screen indicator overlay (icons at the measure's
            // top-right) can consult them without re-walking
            // `score.staves`.
            let sourceMeasure = context.score.staves.first
                .flatMap { $0.measures.indices.contains(measureIdx)
                    ? $0.measures[measureIdx]
                    : nil }
            layoutMeasures.append(LayoutMeasure(
                measureIndex: measureIdx,
                origin: CGPoint(x: xCursor, y: 0),
                width: w,
                elements: aggregated,
                markers: markers,
                jumps: jumps,
                lineBreak: sourceMeasure?.lineBreak ?? false,
                pageBreak: sourceMeasure?.pageBreak ?? false
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
            metrics: metrics)
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
                    origin: CGPoint(x: $0.origin.x, y: $0.origin.y + topShift))
            }
            : labels

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
            partLabels: adjustedLabels,
            spanners: []
        )
    }

    /// Compute the y extent (min/max) of every placed element across all
    /// measures of a system. Used to size the system so notes on far
    /// ledger lines, tempo glyphs, dynamics, etc. don't clip.
    private static func elementYBounds(
        in measures: [LayoutMeasure],
        metrics: StaffMetrics
    ) -> (min: CGFloat, max: CGFloat) {
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        // Glyph metrics are anchored at their center; extend by one sp
        // in every direction so the reported bounds cover the rendered
        // pixels, not just the anchor point.
        let glyphPad = metrics.sp
        for measure in measures {
            for el in measure.elements + measure.markers + measure.jumps {
                for p in elementYPoints(el) {
                    minY = min(minY, p - glyphPad)
                    maxY = max(maxY, p + glyphPad)
                }
            }
        }
        if !minY.isFinite { minY = 0 }
        if !maxY.isFinite { maxY = 0 }
        return (minY, maxY)
    }

    /// y values contributed by a single LayoutElement.
    private static func elementYPoints(
        _ element: LayoutElement
    ) -> [CGFloat] {
        switch element {
        case .clef(_, let p),
             .keySignature(_, _, let p),
             .timeSignature(_, _, let p),
             .barLine(_, let p),
             .textMark(_, _, let p),
             .fermata(_, let p),
             .marker(_, _, let p),
             .jump(_, let p),
             .measureRepeat(_, let p),
             .measureNumber(_, let p),
             .staffName(_, let p),
             .staffText(_, let p, _, _):
            return [p.y]
        case .rest(_, let p, _, _, _):
            return [p.y]
        case .note(_, _, _, _, let p, _, _, _):
            return [p.y]
        case .chord(let notes, _, _, let so, _, _, _, _):
            var ys = notes.map(\.origin.y)
            ys.append(so.y)
            return ys
        case .beam(let from, let to, _, _):
            // fromOrigin, toOrigin, direction, level — only endpoints
            // contribute to the bbox at the primary-beam y; secondary
            // bars stack a fraction of sp away and are accounted for
            // by the generic glyphPad in elementYBounds.
            return [from.y, to.y]
        case .spannerSegment(_, let from, let to, _, _, _),
             .tieArc(let from, let to, _),
             .glissandoLine(let from, let to, _, _):
            return [from.y, to.y]
        case .arpeggioWiggle(let top, let bot, _):
            return [top.y, bot.y]
        case .tupletLabel(let from, let to, _, _, _):
            return [from.y, to.y]
        case .lyricsMelisma(let from, let to),
             .lyricHyphen(let from, let to):
            return [from.y, to.y]
        }
    }

    /// Shift lyric text and lyric hyphens by `dy`. Excludes
    /// melisma rules, which are snapped absolutely by
    /// `setMelismaAbsoluteY` after this pass.
    private static func shiftLyricTextY(
        _ element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func bump(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case .textMark(let kind, let text, let p)
            where kind == .lyrics:
            return .textMark(kind: kind, text: text, origin: bump(p))
        case .lyricHyphen(let from, let to):
            return .lyricHyphen(
                fromOrigin: bump(from), toOrigin: bump(to))
        default:
            return element
        }
    }

    /// Force every `.lyricsMelisma` to `y` regardless of its
    /// originating Y. See the call site in the system-wide
    /// alignment pass for the rationale.
    private static func setMelismaAbsoluteY(
        _ element: LayoutElement, y: CGFloat
    ) -> LayoutElement {
        if case .lyricsMelisma(let from, let to) = element {
            return .lyricsMelisma(
                fromOrigin: CGPoint(x: from.x, y: y),
                toOrigin: CGPoint(x: to.x, y: y))
        }
        return element
    }

    private static func shiftMeasure(
        _ measure: LayoutMeasure, dy: CGFloat
    ) -> LayoutMeasure {
        LayoutMeasure(
            measureIndex: measure.measureIndex,
            origin: measure.origin,
            width: measure.width,
            elements: measure.elements.map { translate(element: $0, dy: dy) },
            markers: measure.markers.map { translate(element: $0, dy: dy) },
            jumps: measure.jumps.map { translate(element: $0, dy: dy) },
            lineBreak: measure.lineBreak,
            pageBreak: measure.pageBreak
        )
    }

    /// Shift an element's origin(s) by a vertical offset, for stacking
    /// staves that were placed in staff-0-local coordinates.
    static func translate(
        element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case .clef(let t, let p):
            return .clef(rawType: t, origin: shift(p))
        case .keySignature(let s, let f, let p):
            return .keySignature(sharps: s, flats: f, origin: shift(p))
        case .timeSignature(let n, let d, let p):
            return .timeSignature(
                numerator: n, denominator: d, origin: shift(p))
        case .barLine(let s, let p):
            return .barLine(subtype: s, origin: shift(p))
        case let .rest(d, p, vi, rid, hll):
            return .rest(
                duration: d, origin: shift(p),
                voiceIndex: vi, restID: rid,
                hasLegerLine: hll)
        case .chord(let notes, let dur, let stem, let so,
                    let arp, let art, let beamed, let vi):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    noteID: $0.noteID,
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando,
                    headType: $0.headType
                )
            }
            return .chord(
                notes: shiftedNotes,
                duration: dur,
                stem: stem,
                stemOrigin: shift(so),
                hasArpeggio: arp,
                arpeggioRawType: art,
                isBeamed: beamed,
                voiceIndex: vi
            )
        case .textMark(let k, let t, let p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case .fermata(let s, let p):
            return .fermata(subtype: s, origin: shift(p))
        case .measureRepeat(let c, let p):
            return .measureRepeat(count: c, origin: shift(p))
        case .beam(let from, let to, let direction, let level):
            return .beam(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                direction: direction,
                level: level)
        case .glissandoLine(let from, let to, let wavy, let text):
            return .glissandoLine(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                wavy: wavy,
                text: text)
        case .arpeggioWiggle(let top, let bot, let subtype):
            return .arpeggioWiggle(
                top: shift(top),
                bottom: shift(bot),
                subtype: subtype)
        case .tupletLabel(let from, let to, let text, let bracket, let above):
            return .tupletLabel(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                text: text,
                hasBracket: bracket,
                isAbove: above)
        case .lyricsMelisma(let from, let to):
            return .lyricsMelisma(
                fromOrigin: shift(from),
                toOrigin: shift(to))
        case .lyricHyphen(let from, let to):
            return .lyricHyphen(
                fromOrigin: shift(from),
                toOrigin: shift(to))
        case .staffText(let text, let p, let color, let isSystem):
            // Emitted by `placeMeasureElements` in staff-local
            // coords (relative to a virtual staff with top at
            // sp * 2), so the per-staff `dy` must be applied for
            // the text to land above its OWN staff. Without this
            // shift every staff's text rendered above staff 0.
            return .staffText(
                text: text,
                origin: shift(p),
                color: color,
                isSystemText: isSystem)
        case .note, .marker, .jump, .measureNumber, .staffName,
             .spannerSegment, .tieArc:
            return element
        }
    }

}
