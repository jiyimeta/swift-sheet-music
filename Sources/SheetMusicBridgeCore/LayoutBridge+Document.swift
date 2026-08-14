import Foundation
import SheetMusicCore
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
        return (layout, DrawProgramCodec.encode(pages: pages), prepared)
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
            let breakPolicy: LayoutBreakPolicy = optionsWire.honorLayoutBreaks == 1 ? .honor : .ignoreAll
            let ranges = LayoutPaginator.paginate(
                systems: document.systems, pageHeight: pageHeightPt, policy: breakPolicy,
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
    /// `wrap` / `title` vary per mode (horizontal disables both); the break /
    /// multi-measure-rest / invisible toggles come straight from the blob.
    private static func scoreViewOptions(
        from optionsWire: LayoutOptionsWire,
        wrap: Bool,
        title: Bool,
    ) -> ScoreViewOptions {
        let staffSize = CGFloat(optionsWire.staffSize)
        let breakPolicy: LayoutBreakPolicy = optionsWire.honorLayoutBreaks == 1 ? .honor : .ignoreAll
        let mmrPolicy: MultiMeasureRestPolicy = optionsWire.collapseMultiMeasureRests == 1
            ? .collapse(minimumMeasures: 2) : .disabled
        return ScoreViewOptions(
            staffSize: staffSize,
            systemGap: staffSize * 1.25,
            wrapToViewWidth: wrap,
            includeTitleFrame: title,
            breakPolicy: breakPolicy,
            breakIndicatorVisibility: .none,
            multiMeasureRest: mmrPolicy,
            showsInvisibleElements: optionsWire.showsInvisibleElements == 1,
            lyricsVisible: optionsWire.lyricsVisible,
        )
    }
}
