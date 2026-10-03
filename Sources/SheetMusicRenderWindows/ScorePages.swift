import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

/// A score laid out and cut into pages for `ScoreSurface.setPages(_:)`: what a Windows host hands the surface, with
/// the layout it came from.
///
/// The pages themselves stay inside the package — they are draw-program commands, a format that grows with every
/// release — so a host holds this value and passes it on. Make one with `compute`; `tinted(argb:ids:)` re-encodes it
/// with a selection drawn in a color.
public struct ScorePages: Sendable {
    /// The full layout, in points. In `.page` mode the continuous one the pages were cut from, so its coordinates are
    /// the document's, not a page's: a page shows it lifted by where that page starts and moved in by the leading and
    /// top margins.
    public let document: LayoutDocument
    /// The score the layout was built from: clef overrides and transposition applied, hidden staves dropped. Its
    /// addresses are the document's. Never the written-pitch view: `ScorePageOptions` leaves the bridge's written-pitch
    /// step off, because a Windows host draws written pitch by transforming the score it passes in.
    public let filteredScore: Score
    /// Where each page shows the document: a document point's page and its position there in millimetres, and back —
    /// how a host puts its own marks (ink, a playback cursor) on the pages as overlays.
    public let placement: ScorePagePlacement

    /// `spans[i]` belongs to `pages[i]`.
    package let pages: [EncodablePage]
    package let spans: [[SystemSpan]]
    package let options: ScorePageOptions
    package let pageWidthMM: Double
    package let pageHeightMM: Double
    /// The score `compute` was given, which a selection is addressed in.
    package let sourceScore: Score

    /// Lays `score` out per `options` and cuts it into pages: in `.vertical` mode one page `pageWidthMM` wide and as
    /// tall as the music, in `.horizontal` one page the size of the music, in `.page` pages of `pageWidthMM` x
    /// `pageHeightMM` with the music inside `options.pageMarginsMM` — every page widened alike when the music overflows
    /// the printable width (`PageMarginsMM`), so lay the pages out by `pageSizeMM(_:)`. Install the font metrics
    /// (`installWindowsFontMetrics(tableBytes:)`) before the first call.
    public static func compute(
        score: Score, pageWidthMM: Double, pageHeightMM: Double, options: ScorePageOptions = .default,
    ) -> ScorePages {
        let laidOut = LayoutBridge.computePages(
            score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: options.wire(),
            margins: options.pageMarginsMM.bridge,
        )
        let placement = ScorePagePlacement(LayoutBridge.pagePlacement(
            document: laidOut.document, options: options.wire(), pageHeightMM: pageHeightMM,
            margins: options.pageMarginsMM.bridge,
        ))
        return ScorePages(
            document: laidOut.document, filteredScore: laidOut.filteredScore, placement: placement,
            pages: laidOut.pages, spans: laidOut.spans, options: options, pageWidthMM: pageWidthMM,
            pageHeightMM: pageHeightMM, sourceScore: score,
        )
    }

    public var pageCount: Int {
        pages.count
    }

    /// Page `page`'s size in millimetres, as drawn — in `.page` mode the widened width when the music overflows the
    /// printable width; `page` must be below `pageCount`.
    public func pageSizeMM(_ page: Int) -> (width: Double, height: Double) {
        (pages[page].widthMM, pages[page].heightMM)
    }

    /// The same layout with the items in `ids` drawn in `argb` (0xAARRGGBB): the pages re-encoded, not laid out again,
    /// so the page count and sizes stay and `ScoreSurface.setPages(_:)` redraws only the systems that changed.
    ///
    /// `ids` are addressed in the score `compute` was given — the addresses edits and a selection hold — and are
    /// moved to the document's addresses as `hiddenStaves` requires; an item on a hidden staff is not drawn, so it
    /// tints nothing. A tuplet tints its bracket and every note and rest it spans (`SelectionExpansion`). The tint
    /// replaces any earlier one, and no id at all gives the untinted pages back.
    public func tinted(argb: UInt32, ids: Set<ScoreItemID>) -> ScorePages {
        var expanded: Set<ScoreItemID> = []
        for id in ids {
            guard case let .item(filtered) = sourceScore.translateCursorForHiddenStaves(
                .item(id), hiddenStaves: options.hiddenStaves,
            ) else { continue }
            expanded.formUnion(SelectionExpansion.expand(filtered, in: filteredScore))
        }
        let tint: (argb: UInt32, ids: Set<ScoreItemID>)? = expanded.isEmpty ? nil : (argb: argb, ids: expanded)
        let built = LayoutBridge.encodePagesWithSpans(
            document: document, options: options.wire(), pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
            margins: options.pageMarginsMM.bridge, tint: tint,
        )
        return ScorePages(
            document: document, filteredScore: filteredScore, placement: placement, pages: built.pages,
            spans: built.spans, options: options, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
            sourceScore: sourceScore,
        )
    }
}
