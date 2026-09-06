import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`,
    /// clashing with SheetMusicLayout's stub. Anchor to the Layout definition.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// Lay out `score` per the display `options` and return both the
    /// `LayoutDocument` and the encoded draw-program payload. Used by
    /// `nativeComputeLayout` to store the layout in `LayoutDocumentCache` so
    /// cursor-frame lookups don't recompute layout.
    ///
    /// The layout mode drives the page model:
    /// - `.vertical` — one continuous page wrapped to the viewport width
    ///   (title block included). Reports the laid-out document height so a
    ///   scroll host can size its content correctly.
    /// - `.horizontal` — one single-system page at the score's natural
    ///   (uncompressed) content width, no title block; the caller scrolls
    ///   it horizontally.
    /// - `.page` — wrapped like `.vertical`, then split into fixed-height
    ///   pages by `LayoutPaginator`. Each emitted page lifts its first
    ///   system to y ≈ 0 so the Kotlin renderer paints page-local coords.
    ///
    /// Clef overrides are applied BEFORE hiding staves because the override
    /// map is keyed on pre-filter staff addresses.
    ///
    /// - Parameters:
    ///   - score: The parsed score.
    ///   - pageWidthMM: Viewport / page width in millimetres.
    ///   - pageHeightMM: Page height in millimetres (only consumed in `.page`
    ///     mode; a viewport hint otherwise).
    ///   - optionsWire: Decoded display options from the Android Reader.
    /// - Returns: Tuple of the `LayoutDocument`, the encoded draw-program
    ///   bytes, and the *filtered* score the layout was built from (clef
    ///   overrides applied, hidden staves dropped) — its addresses match the
    ///   document's keys, which the cursor bridge needs to resolve a
    ///   translated `.beat` cursor against the surviving visible columns. In
    ///   `.page` mode the returned document is the full continuous layout (so
    ///   cursor-frame lookups resolve against absolute document coordinates);
    ///   only the encoded pages are sliced.
    public static func computeWithDocument(
        score: Score,
        pageWidthMM: Double,
        pageHeightMM: Double,
        options optionsWire: LayoutOptionsWire,
    ) -> (document: LayoutDocument, encoded: Data, filteredScore: Score) {
        let result = computeWithPages(
            score: score,
            pageWidthMM: pageWidthMM,
            pageHeightMM: pageHeightMM,
            options: optionsWire,
        )
        return (result.document, DrawProgramCodec.encode(pages: result.pages), result.filteredScore)
    }

    /// `computeWithDocument`, stopping one step short: returns the assembled
    /// `[EncodablePage]` rather than the v6 bytes. See that function for what
    /// each layout mode does to the page model — this is the same call, and the
    /// documentation there is the documentation for this.
    ///
    /// Exists because the WebAssembly bridge hands JavaScript a different
    /// encoding (`DrawProgramFlat`) and would otherwise have to encode to v6 and
    /// decode it straight back. `encodePages` is the expensive half of a layout
    /// pass, so running it twice is not an alternative either.
    package static func computeWithPages(
        score: Score,
        pageWidthMM: Double,
        pageHeightMM: Double,
        options optionsWire: LayoutOptionsWire,
    ) -> (document: LayoutDocument, pages: [EncodablePage], filteredScore: Score) {
        let mmToPt = 72.0 / 25.4
        let pageWidthPt = CGFloat(pageWidthMM * mmToPt)

        // Clef overrides BEFORE hiding staves (override map keyed on the
        // pre-filter address). Transposition sits between the two, matching the
        // Apple Reader's `recomputeVisibleScore`: it re-spells pitches without
        // touching note IDs or ticks, so the cursor bridge's lookups against the
        // resulting document are unaffected either way.
        let prepared = score
            .applying(clefOverrides: optionsWire.clefOverrideMap)
            .transposed(bySemitones: optionsWire.transposeDelta)
            .filtered(hidingStaves: optionsWire.hiddenStaffAddresses)

        let layout: LayoutDocument
        switch optionsWire.mode {
        case .vertical, .page:
            let opts = scoreViewOptions(from: optionsWire, wrap: true, title: true)
            layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: pageWidthPt)
        case .horizontal:
            let opts = scoreViewOptions(from: optionsWire, wrap: false, title: false)
            let natural = LayoutEngine.naturalContentWidth(score: prepared, options: opts)
            layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: natural)
        }

        let pages = encodePages(
            document: layout, options: optionsWire, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
        )
        return (layout, pages, prepared)
    }

    /// Assembles the encoded pages for an already-laid-out `document`, per `options`' layout mode — the
    /// shared "page assembly" step between a fresh `computeWithDocument` layout and
    /// `nativeEncodeDrawProgram`'s re-encode of an already-cached layout (`EditGeometryBridge.swift`). Does
    /// no relayout of its own: `document` is used exactly as given, and `.page` mode's pagination /
    /// subdocument slicing are geometry-only cuts over `document.systems`, not a second `LayoutEngine.layout`
    /// pass.
    ///
    /// `tint` threads straight through to `buildCommands(layout:tint:)` for every page — `nil` (the default)
    /// reproduces `computeWithDocument`'s own untinted bytes exactly, since that is the only caller that
    /// passes no tint.
    ///
    /// - `.vertical` — one page, `pageWidthMM` wide (the caller's viewport — not `document.size.width`, which
    ///   is the narrower rendered content extent) by the document's own laid-out height.
    /// - `.horizontal` — one page sized to `document.size` (both dimensions), since horizontal layout has no
    ///   separate viewport concept — the document *is* the page.
    /// - `.page` — `document.systems` paginated by `LayoutPaginator` at `pageHeightMM`, each page a
    ///   `pageWidthMM` × `pageHeightMM` slice with its first system lifted to y ≈ 0 (mirrors the original
    ///   inline implementation this was extracted from — see the two comments below for why).
    package static func encodePages(
        document: LayoutDocument,
        options optionsWire: LayoutOptionsWire,
        pageWidthMM: Double,
        pageHeightMM: Double,
        tint: (argb: UInt32, ids: Set<ScoreItemID>)? = nil,
    ) -> [EncodablePage] {
        let ptToMM = 25.4 / 72.0

        switch optionsWire.mode {
        case .vertical:
            return [EncodablePage(
                widthMM: pageWidthMM,
                heightMM: Double(document.size.height) * ptToMM,
                commands: buildCommands(layout: document, tint: tint),
            )]

        case .horizontal:
            return [EncodablePage(
                widthMM: Double(document.size.width) * ptToMM,
                heightMM: Double(document.size.height) * ptToMM,
                commands: buildCommands(layout: document, tint: tint),
            )]

        case .page:
            let mmToPt = 72.0 / 25.4
            let pageHeightPt = CGFloat(pageHeightMM * mmToPt)
            let ranges = LayoutPaginator.paginate(
                systems: document.systems, pageHeight: pageHeightPt, policy: optionsWire.breakPolicy,
            )
            return ranges.map { range in
                // Lift each page's first system to y ≈ 0. The first page keeps
                // y = 0 (so the title frame stays visible); later pages shift
                // by the previous system's bottom so the gap above the new
                // page's first system renders on the new page.
                let pageTop: CGFloat = range.lowerBound == 0
                    ? 0
                    : document.systems[range.lowerBound - 1].origin.y
                    + document.systems[range.lowerBound - 1].size.height
                let sub = document.subdocument(systems: range, yOffset: -pageTop)
                // `subdocument` drops the title frame; only the first page (at
                // y = 0) carries it, so re-attach it there. Without this the
                // title block never renders in `.page` mode — the systems were
                // already shifted down for it, leaving a blank gap.
                let pageDoc = range.lowerBound == 0
                    ? LayoutDocument(
                        size: sub.size, systems: sub.systems,
                        metrics: sub.metrics, titleFrame: document.titleFrame,
                    )
                    : sub
                return EncodablePage(
                    widthMM: pageWidthMM,
                    heightMM: pageHeightMM,
                    commands: buildCommands(layout: pageDoc, tint: tint),
                )
            }
        }
    }

    /// Build the `ScoreViewOptions` for one layout pass from the wire options.
    ///
    /// `wrap` varies per mode (horizontal never wraps) and `title` is the mode's *suggestion*, which
    /// `includesTitleFrame(modeDefault:)` lets the host override. Everything else now comes from the
    /// blob; the values this function used to hard-code — the system gap, the multi-measure-rest
    /// threshold, the measure-number policy, the two glyph magnifications, the break-indicator
    /// visibility — are the wire's defaults, so an unchanged host gets an unchanged layout.
    private static func scoreViewOptions(
        from optionsWire: LayoutOptionsWire,
        wrap: Bool,
        title: Bool,
    ) -> ScoreViewOptions {
        let staffSize = CGFloat(optionsWire.staffSize)
        var options = ScoreViewOptions(
            staffSize: staffSize,
            systemGap: CGFloat(optionsWire.systemGap(staffSize: optionsWire.staffSize)),
            wrapToViewWidth: wrap,
            includeTitleFrame: optionsWire.includesTitleFrame(modeDefault: title),
            breakPolicy: optionsWire.breakPolicy,
            breakIndicatorVisibility: optionsWire.breakIndicatorVisibility,
            multiMeasureRest: optionsWire.multiMeasureRestPolicy,
            showsInvisibleElements: optionsWire.showsInvisibleElements == 1,
            measureNumbers: optionsWire.measureNumberPolicy,
            lyricsVisible: optionsWire.lyricsVisible,
        )
        // Assigned after construction rather than passed in, so `0` keeps whatever
        // `ScoreViewOptions` itself defaults to. Naming the literal here would pin the engine's
        // default in a second place and let the two drift.
        if optionsWire.graceNoteMag > 0 { options.graceNoteMag = CGFloat(optionsWire.graceNoteMag) }
        if optionsWire.smallNoteMag > 0 { options.smallNoteMag = CGFloat(optionsWire.smallNoteMag) }
        return options
    }
}
