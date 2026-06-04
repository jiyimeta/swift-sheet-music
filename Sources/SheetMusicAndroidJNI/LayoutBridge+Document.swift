import Foundation
import SheetMusicCore
import SheetMusicLayout

extension LayoutBridge {
    /// Lay out `score` and return both the `LayoutDocument` and the encoded
    /// draw-program payload. Used by `nativeComputeLayout` to store the layout
    /// in `LayoutDocumentCache` so cursor-frame lookups don't recompute layout.
    ///
    /// - Parameters:
    ///   - score: The parsed score.
    ///   - pageWidthMM: Viewport / page width in millimetres.
    ///   - pageHeightMM: Viewport / page height in millimetres.
    /// - Returns: Tuple of the `LayoutDocument` and the encoded draw-program bytes.
    public static func computeWithDocument(
        score: Score,
        pageWidthMM: Double,
        pageHeightMM: Double,
    ) -> (document: LayoutDocument, encoded: Data) {
        // Convert mm → pt for the layout engine's availableWidth.
        let mmToPt = 72.0 / 25.4
        let availableWidthPt = Double(pageWidthMM) * mmToPt

        let options = ScoreViewOptions(
            wrapToViewWidth: true,
            includeTitleFrame: false,
        )
        let layout = LayoutEngine.layout(
            score: score,
            options: options,
            availableWidth: availableWidthPt,
        )

        let commands = buildCommands(layout: layout)
        // `pageHeightMM` is only a viewport hint and is intentionally NOT used as
        // the page height: the layout is continuous (`wrapToViewWidth`), so the
        // page's real height is the laid-out document height. Reporting the hint
        // here (the previous behavior) made scroll-host consumers size their
        // scrollable content too short — everything below the hint height became
        // unreachable. Convert pt → mm so it matches the mm-space draw commands
        // emitted by `buildCommands`.
        let page = EncodablePage(
            widthMM: pageWidthMM,
            heightMM: Double(layout.size.height) / mmToPt,
            commands: commands,
        )
        return (layout, DrawProgramCodec.encode(pages: [page]))
    }
}
