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
    /// - Returns: Tuple of the `LayoutDocument` and the encoded draw-program
    ///   bytes. In `.page` mode the returned document is the full continuous
    ///   layout (so cursor-frame lookups resolve against absolute document
    ///   coordinates); only the encoded pages are sliced.
    public static func computeWithDocument(
        score: Score,
        pageWidthMM: Double,
        pageHeightMM: Double,
        options optionsWire: LayoutOptionsWire,
    ) -> (document: LayoutDocument, encoded: Data) {
        let mmToPt = 72.0 / 25.4
        let ptToMM = 25.4 / 72.0
        let pageWidthPt = CGFloat(pageWidthMM * mmToPt)
        let pageHeightPt = CGFloat(pageHeightMM * mmToPt)

        // Clef overrides BEFORE hiding staves (override map keyed on the
        // pre-filter address).
        let prepared = score
            .applying(clefOverrides: optionsWire.clefOverrideMap)
            .filtered(hidingStaves: optionsWire.hiddenStaffAddresses)

        let breakPolicy: LayoutBreakPolicy = optionsWire.honorLayoutBreaks == 1 ? .honor : .ignoreAll

        switch optionsWire.mode {
        case .vertical:
            let opts = scoreViewOptions(from: optionsWire, wrap: true, title: true)
            let layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: pageWidthPt)
            let page = EncodablePage(
                widthMM: pageWidthMM,
                heightMM: Double(layout.size.height) * ptToMM,
                commands: buildCommands(layout: layout),
            )
            return (layout, DrawProgramCodec.encode(pages: [page]))

        case .horizontal:
            let opts = scoreViewOptions(from: optionsWire, wrap: false, title: false)
            let natural = LayoutEngine.naturalContentWidth(score: prepared, options: opts)
            let layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: natural)
            let page = EncodablePage(
                widthMM: Double(layout.size.width) * ptToMM,
                heightMM: Double(layout.size.height) * ptToMM,
                commands: buildCommands(layout: layout),
            )
            return (layout, DrawProgramCodec.encode(pages: [page]))

        case .page:
            let opts = scoreViewOptions(from: optionsWire, wrap: true, title: true)
            let layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: pageWidthPt)
            let ranges = LayoutPaginator.paginate(
                systems: layout.systems, pageHeight: pageHeightPt, policy: breakPolicy,
            )
            let pages: [EncodablePage] = ranges.map { range in
                // Lift each page's first system to y ≈ 0. The first page keeps
                // y = 0 (so the title frame stays visible); later pages shift
                // by the previous system's bottom so the gap above the new
                // page's first system renders on the new page.
                let pageTop: CGFloat = range.lowerBound == 0
                    ? 0
                    : layout.systems[range.lowerBound - 1].origin.y
                    + layout.systems[range.lowerBound - 1].size.height
                let sub = layout.subdocument(systems: range, yOffset: -pageTop)
                return EncodablePage(
                    widthMM: pageWidthMM,
                    heightMM: pageHeightMM,
                    commands: buildCommands(layout: sub),
                )
            }
            return (layout, DrawProgramCodec.encode(pages: pages))
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
        )
    }
}
