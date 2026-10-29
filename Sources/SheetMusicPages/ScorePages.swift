import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

/// A score laid out and cut into pages, with the layout it came from: what a Windows host hands its surface
/// (`ScoreSurface.setPages(_:)`), and what a PDF writer writes.
///
/// The pages themselves stay inside the package — they are draw-program commands, a format that grows with every
/// release — so a host holds this value and passes it on, or hands them to the Kotlin renderer of the same release as
/// its versioned wire (`encodedDrawProgram()`). Make one with `compute`; `tinted(argb:ids:)` re-encodes it with a
/// selection drawn in a color.
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
    /// (`installWindowsFontMetrics(tableBytes:)` on Windows, `installFontMetricsTable(_:)` elsewhere) before the first
    /// call.
    public static func compute(
        score: Score, pageWidthMM: Double, pageHeightMM: Double, options: ScorePageOptions = .default,
    ) -> ScorePages {
        let laidOut = LayoutBridge.computePages(
            score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: options.wire(),
            margins: options.pageMarginsMM.bridge, drawsInvisibleElements: options.drawsInvisibleElements,
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

    /// Every page as one encoded draw program, in page order: the wire the same release's Kotlin
    /// `DrawProgramReader.decode` reads, into one decoded page per page here — one in `.vertical` and `.horizontal`
    /// mode, `pageCount` in `.page`. With no page margins it is byte for byte the payload the Android Reader's
    /// `nativeComputeLayout` returns for the same score and options.
    ///
    /// For a host that lays out in its own Swift code and draws in Kotlin (`drawScoreCommands`): a JNI entry reads the
    /// library's process-wide font metrics, while `compute` inside `FontMetrics.withProvider(_:operation:)` reads the
    /// scope's, so a layout measured with the portable table on every platform has to be computed here and handed
    /// over as these bytes.
    ///
    /// The whole document rather than a page at a time: the wire is a list of pages, which is what the Kotlin reader
    /// decodes and what the Android Reader and its PDF exporter already consume, and the non-paged modes are a single
    /// page anyway.
    ///
    /// It serializes the pages `compute` (or `tinted(argb:ids:)`) built and measures nothing, so the metrics that
    /// count are the ones in force around that call, not this one. The format is versioned
    /// (`DrawProgramReader` refuses any other version), so decode it with the Kotlin library of the same release.
    public func encodedDrawProgram() -> Data {
        DrawProgramCodec.encode(pages: pages)
    }

    /// Page `page`'s draw commands one system at a time, for a host that draws a system on its own — caching one
    /// recording per system, say, or drawing only the systems a view shows: each system's run of the page's commands,
    /// as indices into that page of `encodedDrawProgram()`, in command order and covering the page's commands exactly.
    ///
    /// `systemIndex` is the system's index in `document.systems` — in `.page` mode the document's, not the page's — and
    /// `nil` for the title block's run, which comes first on the page that draws it, and for each box between systems,
    /// just before the system below it. A run replayed alone, from the draw program's default state, paints what the
    /// whole page paints there: every state a command sets (color, dash, rotation, text style) is set and reset within
    /// the element that needs it. A system's run can paint outside its own frame — slurs, ottava lines and brackets
    /// reach past it — so a host that wants nothing of a neighboring system draws only the runs it means to.
    ///
    /// `page` must be below `pageCount`.
    public func systemCommandRanges(onPage page: Int) -> [(systemIndex: Int?, commands: Range<Int>)] {
        spans[page].map { (systemIndex: $0.systemIndex, commands: $0.commandRange) }
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
            margins: options.pageMarginsMM.bridge, tint: tint, drawsInvisibleElements: options.drawsInvisibleElements,
        )
        return ScorePages(
            document: document, filteredScore: filteredScore, placement: placement, pages: built.pages,
            spans: built.spans, options: options, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
            sourceScore: sourceScore,
        )
    }
}
