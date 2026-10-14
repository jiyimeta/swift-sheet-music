#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutTitleFrame {
    /// One line of a title-block text, already placed: the string, the point its anchor lands on, and how that
    /// anchor divides the line horizontally.
    ///
    /// **The anchor is always on the line's TOP edge.** A bottom-anchored block is expressed by shifting the first
    /// line's `y` up by the block height instead, so a caller only ever has to honour three horizontal alignments.
    ///
    /// This is the one statement of WHERE a title-block line goes. The screen's layer tree, the PDF's `Canvas` and a
    /// host placing an inline editor over a credit all read it, so none of them can drift from the others.
    public struct PlacedLine: Sendable, Equatable {
        public let text: String
        /// Index into `LayoutTitleFrame.texts` of the entry this line was split from.
        public let entryIndex: Int
        /// This line's position within its entry, from the top.
        public let lineIndex: Int
        /// Where the anchor lands: `x` per `horizontalAnchor`, `y` the line's top edge.
        public let position: CGPoint
        /// How much of the line lies to the LEFT of `position.x`: 0 leading, 0.5 centered, 1 trailing.
        public let horizontalAnchor: CGFloat
        public let fontSize: CGFloat
        /// The line's typeset runs, for an entry that has them (`LayoutFrameText.richText`). A renderer draws them
        /// placed (`positionedRuns`, `decorations`).
        let richLine: LayoutRichTextLine?
    }

    /// The vertical step between two lines of one plain entry. SwiftUI's `Text` resolves with the system line-height
    /// factor (~1.2 × point size), and the renderers stack lines at exactly that, so this is the number they share. An
    /// entry with runs steps each line by that line's own metrics instead (`richLineTops`).
    public static func lineHeight(fontSize: CGFloat) -> CGFloat {
        fontSize * 1.2
    }

    /// The font a title-block text of `size` points is set in: the platform UI face (`LayoutFont`'s empty face — SF
    /// on Apple), regular and upright, since MuseScore defaults all four title-block styles to `FontStyle::Normal`
    /// (`engraving/style/styledef.cpp`). `size` is the entry's `fontSize`, already resolved per style by the layout.
    ///
    /// **The one statement of WHICH face the title block is in.** The Apple renderers (`TitleFrameRenderer`, the
    /// screen's layer tree and the PDF alike), the draw-program bridge and `CreditTextLine` all read it, so the face a
    /// line is anchored with and the face it is drawn in cannot part. A measuring host resolves it first
    /// (`FontMetricsProvider.renderingTextFont`): a table provider, which carries no system face, answers Edwin.
    package static func font(size: CGFloat) -> LayoutFont {
        LayoutFont(face: "", pointSize: size)
    }

    /// Every line of every entry, in entry order, offset by `origin`.
    ///
    /// Multi-line `<Text>` blocks (e.g. test-platinum.mscx's three Lyricist lyric columns) are split on `\n` and each
    /// line placed at its own `y` with the entry's horizontal anchor — `Canvas.resolve` only takes a `Text` literal,
    /// so SwiftUI's `.multilineTextAlignment` cannot reach them.
    public func placedLines(origin: CGPoint = .zero) -> [PlacedLine] {
        texts.enumerated().flatMap { entryIndex, entry in
            Self.placedLines(of: entry, entryIndex: entryIndex, origin: origin)
        }
    }

    private static func placedLines(of entry: LayoutFrameText, entryIndex: Int, origin: CGPoint) -> [PlacedLine] {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let richLines = entry.richText?.lines
        let count = richLines?.count ?? lines.count
        let x = origin.x + entry.position.x
        let y = origin.y + entry.position.y
        let tops: [CGFloat]
        if let richLines {
            tops = richLineTops(richLines, fontSize: entry.fontSize, y: y, isBottom: entry.anchor.isBottom)
        } else {
            let lineHeight = lineHeight(fontSize: entry.fontSize)
            let topY = entry.anchor.isBottom ? y - CGFloat(count) * lineHeight : y
            tops = (0 ..< count).map { topY + CGFloat($0) * lineHeight }
        }
        return (0 ..< count).map { lineIndex in
            PlacedLine(
                text: lineIndex < lines.count ? lines[lineIndex] : "",
                entryIndex: entryIndex,
                lineIndex: lineIndex,
                position: CGPoint(x: x, y: tops[lineIndex]),
                horizontalAnchor: entry.anchor.horizontalFraction,
                fontSize: entry.fontSize,
                richLine: richLines?[lineIndex],
            )
        }
    }

    /// The top edge of each line of an entry with runs. A rich line's baseline sits one of its OWN ascents below its
    /// top (`positionedRuns`), so it steps by its own ascent and descent plus the gap a plain line leaves below its
    /// face's — `lineHeight(fontSize:)` less that face's ascent and descent. A line in the block's face therefore steps
    /// exactly as a plain line does, and one with a larger `<font size>` run pushes the next line down instead of into
    /// it. A bottom-anchored entry rises by the sum of the steps, as a plain one rises by `count` line heights. The
    /// equality assumes the runs were typeset in `renderingTextFont(font(size:))` (`LayoutEngine.titleRichText` does),
    /// so a plain-format line's ascent and descent are that face's own.
    private static func richLineTops(
        _ lines: [LayoutRichTextLine], fontSize: CGFloat, y: CGFloat, isBottom: Bool,
    ) -> [CGFloat] {
        let provider = FontMetrics.provider
        let face = provider.renderingTextFont(font(size: fontSize))
        let gap = lineHeight(fontSize: fontSize) - provider.ascent(font: face) - provider.descent(font: face)
        let steps = lines.map { $0.ascent + $0.descent + gap }
        var top = isBottom ? y - steps.reduce(0, +) : y
        var tops: [CGFloat] = []
        for step in steps {
            tops.append(top)
            top += step
        }
        return tops
    }
}

extension LayoutFrameText.Anchor {
    /// How much of the text lies to the left of the anchor point: 0 leading, 0.5 centered, 1 trailing.
    public var horizontalFraction: CGFloat {
        switch self {
        case .topLeading, .bottomLeading: 0
        case .top, .bottom: 0.5
        case .topTrailing, .bottomTrailing: 1
        }
    }

    var isBottom: Bool {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: true
        case .topLeading, .top, .topTrailing: false
        }
    }
}

extension LayoutTitleFrame.PlacedLine {
    /// The rich line's runs on the page, or none for a plain line: pen start `position.x` less `horizontalAnchor` of
    /// the line's advance width (how a plain line is anchored too), baseline one ascent below the top edge — where the
    /// renderers put a plain line's baseline (`TitleFrameLayerBuilder`, `LayoutBridge.appendTitleEntry`).
    public var positionedRuns: [LayoutRichTextPositionedRun] {
        guard let richLine else { return [] }
        return richLine.positionedRuns(
            leftX: position.x - horizontalAnchor * richLine.width, baselineY: position.y + richLine.ascent,
        )
    }

    /// The underline and strike-through bars for the same placement.
    public var decorations: [LayoutRichTextDecoration] {
        guard let richLine else { return [] }
        return richLine.decorations(
            leftX: position.x - horizontalAnchor * richLine.width, baselineY: position.y + richLine.ascent,
        )
    }
}
