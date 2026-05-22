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
        let page = EncodablePage(
            widthMM: pageWidthMM,
            heightMM: pageHeightMM,
            commands: commands,
        )
        return (layout, DrawProgramCodec.encode(pages: [page]))
    }
}
