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
    }

    /// The vertical step between two lines of one entry. SwiftUI's `Text` resolves with the system line-height
    /// factor (~1.2 × point size), and the renderers stack lines at exactly that, so this is the number they share.
    public static func lineHeight(fontSize: CGFloat) -> CGFloat {
        fontSize * 1.2
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
        let lineHeight = lineHeight(fontSize: entry.fontSize)
        let x = origin.x + entry.position.x
        let y = origin.y + entry.position.y
        let topY = entry.anchor.isBottom ? y - CGFloat(lines.count) * lineHeight : y
        return lines.enumerated().map { lineIndex, line in
            PlacedLine(
                text: line,
                entryIndex: entryIndex,
                lineIndex: lineIndex,
                position: CGPoint(x: x, y: topY + CGFloat(lineIndex) * lineHeight),
                horizontalAnchor: entry.anchor.horizontalFraction,
                fontSize: entry.fontSize,
            )
        }
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
