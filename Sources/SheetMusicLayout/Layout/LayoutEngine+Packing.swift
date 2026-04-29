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
              !firstStaff.measures.isEmpty else {
            return []
        }

        let measureCount = firstStaff.measures.count
        // Per-measure minimum width via the same cross-staff
        // tick-aggregation `tickColumns` will use, so the spacing
        // pass and the placement pass agree on segment widths.
        // (Per-staff `minimumMeasureWidth` undercounts when other
        // staves subdivide a long element — see
        // `crossStaffMinimumMeasureWidth`.)
        let minWidths: [CGFloat] = (0..<measureCount).map { i in
            let baseHeader = computeHeaderSchedule(
                measureIdx: i,
                staves: context.score.staves,
                metrics: context.metrics,
                synthesizeClefForAllStaves: false,
                synthesizeKeySigForAllStaves: false)
            return crossStaffMinimumMeasureWidth(
                staves: context.score.staves,
                measureIdx: i,
                metrics: context.metrics,
                headerSchedule: baseHeader,
                division: context.score.division)
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
            let stretched: [CGFloat]
            if context.options.wrapToViewWidth {
                stretched = stretchWidths(
                    widths: widthsSlice,
                    availableWidth: contentAvail,
                    shouldStretch: true)
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
}
