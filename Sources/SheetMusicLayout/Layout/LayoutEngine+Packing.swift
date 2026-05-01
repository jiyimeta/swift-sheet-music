// swiftlint:disable function_body_length file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    // MARK: - System packing

    static func packSystems(
        context: RenderContext
    ) -> [LayoutSystem] {
        let stavesCount = context.score.staves.count
        guard stavesCount > 0,
              let firstStaff = context.score.staves.first,
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
        let sp = context.metrics.sp
        let division = context.score.division
        // Per-measure minimum width via the same cross-staff
        // tick-aggregation `tickColumns` will use, so the spacing
        // pass and the placement pass agree on segment widths.
        // (Per-staff `minimumMeasureWidth` undercounts when other
        // staves subdivide a long element — see
        // `crossStaffMinimumMeasureWidth`.)
        let minWidths: [CGFloat] = (0 ..< measureCount).map { i in
            let measuresAt = context.score.staves.map { staff in
                i < staff.measures.count ? staff.measures[i] : nil
            }
            if let prior = priorEntries[i],
               prior.sp == sp,
               prior.division == division,
               prior.measures == measuresAt
            {
                // Cache hit: copy the prior entry forward verbatim.
                // `buildSystem` will trust its `placements` only
                // when the per-staff inputs also match.
                context.cache?.entries[i] = prior
                context.cache?.widthHits += 1
                return prior.minWidth
            }
            context.cache?.widthMisses += 1
            let baseHeader = computeHeaderSchedule(
                measureIdx: i,
                staves: context.score.staves,
                metrics: context.metrics,
                synthesizeClefForAllStaves: false,
                synthesizeKeySigForAllStaves: false
            )
            let w = crossStaffMinimumMeasureWidth(
                staves: context.score.staves,
                measureIdx: i,
                metrics: context.metrics,
                headerSchedule: baseHeader,
                division: division
            )
            context.cache?.entries[i] = LayoutCache.Entry(
                measures: measuresAt,
                sp: sp,
                division: division,
                minWidth: w,
                placements: [:]
            )
            return w
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
            count: context.score.staves.count
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
        let firstSystemLabelW = labelWidth(
            score: context.score,
            metrics: context.metrics,
            useLong: true
        )
        let continuationLabelW = labelWidth(
            score: context.score,
            metrics: context.metrics,
            useLong: false
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
                    staves: context.score.staves
                )
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
                    && widthSoFar + w > naturalAvail
                {
                    break
                }
                if context.options.wrapToViewWidth
                    && cursor - systemStart >= balancedTarget
                {
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
                       staves: context.score.staves
                   )
                {
                    break
                }
            }
            var widthsSlice = Array(minWidths[systemStart ..< cursor])
            if !widthsSlice.isEmpty {
                widthsSlice[0] += firstHeaderBoost
            }
            let stretched: [CGFloat]
            if context.options.wrapToViewWidth {
                stretched = stretchWidths(
                    widths: widthsSlice,
                    availableWidth: contentAvail,
                    shouldStretch: true
                )
            } else {
                // Horizontal (no-wrap) mode: there's no viewport
                // width to stretch into, so without a fixed scale
                // measures collapse to their minimums. The
                // minimum widths are tuned for the wrapped layout
                // where the viewport stretches them ~1.5×; apply
                // the same `naturalStretch` here so horizontal
                // mode has matching breathing room.
                stretched = widthsSlice.map { $0 * naturalStretch }
            }
            // Snapshot carry-in state BEFORE buildSystem mutates it.
            // Used either as cache key (on miss store) or for hit check.
            let activeClefsIn = activeClefs
            let activeKeysIn = activeKeys
            let measureCount = cursor - systemStart
            let inputs = systemInputs(
                measureStart: systemStart,
                measureCount: measureCount,
                widths: stretched,
                isFirstSystem: isFirstSystem,
                activeClefsIn: activeClefsIn,
                activeKeysIn: activeKeysIn,
                context: context
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
                    widths: stretched,
                    systemOriginY: 0,
                    isFirstSystem: isFirstSystem,
                    activeClefs: &activeClefs,
                    activeKeys: &activeKeys,
                    context: context
                )
                system = shift(unshifted, byY: currentY)
                context.cache?.systemEntries[systemStart] = LayoutCache
                    .SystemEntry(
                        inputs: inputs,
                        system: unshifted,
                        activeClefsOut: activeClefs,
                        activeKeysOut: activeKeys
                    )
                context.cache?.systemMisses += 1
            }
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
        staves.indices.map { idx in
            let part = idx < parts.count ? parts[idx] : nil
            let decl = part?.staffDeclarations.first
            if let declared = decl?.defaultClefType {
                return declared
            }
            if decl?.group == "percussion" { return "PERC" }
            return "G"
        }
    }

    /// Build a `LayoutCache.SystemInputs` snapshot for the given
    /// system. The snapshot is the cache-hit predicate — every input
    /// that affects `buildSystem` output (apart from `systemOriginY`,
    /// which is normalised away) must appear here.
    static func systemInputs(
        measureStart: Int,
        measureCount: Int,
        widths: [CGFloat],
        isFirstSystem: Bool,
        activeClefsIn: [NotatedClef],
        activeKeysIn: [Int],
        context: RenderContext
    ) -> LayoutCache.SystemInputs {
        let staves = context.score.staves
        let measuresPerStaff: [[Measure?]] = staves.map { staff in
            (0 ..< measureCount).map { local in
                let abs = measureStart + local
                return abs < staff.measures.count
                    ? staff.measures[abs] : nil
            }
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
        let drumLineMaps: [[Int: Int]?] = staves.indices.map { idx in
            let part = idx < context.score.parts.count
                ? context.score.parts[idx] : nil
            return part?.instrument.useDrumset == true
                ? part?.instrument.drumLineMap : nil
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
            effectiveMelismaTicks: context.effectiveMelismaTicks,
            melismaContinuationsForRange: melismaForRange,
            drumLineMaps: drumLineMaps,
            totalMeasures: staves.first?.measures.count ?? 0,
            options: context.options
        )
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
}
