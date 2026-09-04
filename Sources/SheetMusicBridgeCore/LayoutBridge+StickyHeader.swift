import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

extension LayoutBridge {
    /// The sticky-header pane for a horizontal continuous view, as a one-page draw program.
    ///
    /// MuseScore's continuous view freezes the current clef, key signature, time signature and
    /// instrument name at the viewport's left edge, so a reader who has scrolled past bar 1 can
    /// still see what key and metre they are in. `SheetMusicUI.StickyHeaderView` does exactly that
    /// on Apple; nothing on Android or in the browser could, because the pane is a *synthesized*
    /// system rather than a slice of the score, and nothing bridged the synthesis.
    ///
    /// The engraving is not reimplemented here. `LayoutEngine.stickyHeaderSystem` — portable, in
    /// `SheetMusicLayout`, and what the Apple view calls — builds the `LayoutSystem`; this wraps it
    /// in a one-system `LayoutDocument` and hands it to the same `buildCommands` every other page
    /// goes through. Any change to how a clef or a key signature is drawn therefore reaches the
    /// sticky pane for free, which is the whole reason to route it this way rather than emit a few
    /// glyphs directly.
    ///
    /// - Parameter scrollXPt: the viewport's left edge in document points. The pane reflects the
    ///   measure under that x — the one the reader is looking at, not the one they started from.
    ///
    /// `Double` rather than `CGFloat` deliberately: on Android this file's `CGFloat` is a *private*
    /// file-scoped typealias onto `SheetMusicLayout`'s stub (Foundation's CoreGraphics shims export
    /// a clashing one), and a public method cannot take a private type. The whole bridge boundary is
    /// `Double` anyway, so this is the shape a caller wants.
    ///
    /// Returns `nil` when the document has no systems (nothing to freeze) or the score has no
    /// measures. A scroll position past the last measure clamps to the last one rather than
    /// disappearing: a header that vanishes at the end of a score is worse than one that stops
    /// changing.
    @available(macOS 15.0, iOS 16.0, *)
    public static func stickyHeaderPage(
        score: Score,
        document: LayoutDocument,
        scrollXPt: Double,
    ) -> EncodablePage? {
        guard let template = document.systems.first else { return nil }
        let contexts = LayoutEngine.measureContexts(for: score)
        guard !contexts.isEmpty else { return nil }

        // `measureIndex(atDocumentX:)` answers nil left of the first measure and right of the last;
        // both clamp rather than refuse, for the reason in the doc comment above.
        let rawIndex = document.measureIndex(atDocumentX: CGFloat(scrollXPt)) ?? 0
        let index = max(0, min(rawIndex, contexts.count - 1))

        let synthesized = LayoutEngine.stickyHeaderSystem(
            for: contexts[index],
            templateSystem: template,
            metrics: document.metrics,
        )
        let pane = LayoutDocument(
            size: synthesized.size,
            systems: [synthesized],
            metrics: document.metrics,
        )
        return EncodablePage(
            widthMM: Double(synthesized.size.width) * ptToMMScale,
            heightMM: Double(synthesized.size.height) * ptToMMScale,
            commands: buildCommands(layout: pane),
        )
    }
}
