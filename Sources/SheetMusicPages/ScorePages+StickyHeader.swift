import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

extension ScorePages {
    /// The sticky header of a horizontal strip for the measure under `scrollXPt`, as a one-page `ScorePages` a host
    /// draws on its own `ScoreSurface` pinned at the viewport's leading edge — MuseScore's continuous-view panel and
    /// the Apple `StickyHeaderView`: per staff the clef, key signature and time signature in force, the part labels and
    /// the bracket, synthesized by `LayoutEngine.stickyHeaderSystem` on this layout's staff origins, so they line up
    /// with the staves they cover (`LayoutBridge.stickyHeaderDocument`).
    ///
    /// `scrollXPt` is in this layout's document points; a host passes the pane's trailing edge
    /// (`LayoutDocument.stickyTrailingX(scoreScrollX:measureContexts:)`), so the pane flips when the next measure
    /// clears it, as the Apple container does. A scroll past either end clamps to the first or last measure.
    ///
    /// The result's `document` is the one-system pane (its `size` is the pane's), on one page sized to it at the
    /// origin. It is drawn as the score is, black on white; MuseScore and `StickyHeaderView` show it at 50 %, which a
    /// host gets by laying a 50 % white over its pane. `nil` when this layout has no systems or the score no measures.
    public func stickyHeader(scrollXPt: Double) -> ScorePages? {
        guard let pane = LayoutBridge.stickyHeaderDocument(
            score: filteredScore, document: document, scrollXPt: scrollXPt,
        ) else { return nil }
        var paneOptions = options
        paneOptions.mode = .horizontal
        paneOptions.pageMarginsMM = .zero
        let wire = paneOptions.wire()
        // A horizontal page is the document's own size; these are what `tinted(argb:ids:)` hands the encoder back.
        let widthMM = Double(pane.size.width) * 25.4 / 72
        let heightMM = Double(pane.size.height) * 25.4 / 72
        let built = LayoutBridge.encodePagesWithSpans(
            document: pane, options: wire, pageWidthMM: widthMM, pageHeightMM: heightMM,
            drawsInvisibleElements: options.drawsInvisibleElements,
        )
        let placement = ScorePagePlacement(
            LayoutBridge.pagePlacement(document: pane, options: wire, pageHeightMM: heightMM),
        )
        return ScorePages(
            document: pane, filteredScore: filteredScore, placement: placement, pages: built.pages,
            spans: built.spans, options: paneOptions, pageWidthMM: widthMM, pageHeightMM: heightMM,
            sourceScore: sourceScore,
        )
    }
}
