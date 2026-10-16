#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

public struct LayoutDocument: Sendable, Equatable {
    public let size: CGSize
    public let systems: [LayoutSystem]
    public let metrics: StaffMetrics
    /// Resolved title block for the top of the document, when the
    /// score has a leading `<VBox>`. Renderers draw this above the
    /// first system; PDF pagination treats its height as part of
    /// page 1's content budget.
    public let titleFrame: LayoutTitleFrame?
    /// The score's chord-symbol case style (`Score.style.chordSymbolCase`) this document was laid out with. A host that
    /// measures a chord symbol itself (`HarmonyRendering.runs`, `caretOffsets`) must pass this, or it measures a
    /// different string than the one drawn.
    public let chordSymbolCase: ChordSymbolCaseStyle
    /// The boxes after the leading one (`<VBox>` / `<TBox>` between systems), top to bottom, in document coordinates.
    /// Empty for a score with only a title block.
    public let frames: [LayoutFrame]
    /// The leading box's pictures, in document coordinates (margins included, like the texts of `titleFrame`). They
    /// live here because `LayoutTitleFrame` carries no images.
    public let titleImages: [LayoutFrameImage]

    public init(
        size: CGSize,
        systems: [LayoutSystem],
        metrics: StaffMetrics,
        titleFrame: LayoutTitleFrame? = nil,
        chordSymbolCase: ChordSymbolCaseStyle = .museScoreDefaults,
        frames: [LayoutFrame] = [],
        titleImages: [LayoutFrameImage] = [],
    ) {
        self.size = size
        self.systems = systems
        self.metrics = metrics
        self.titleFrame = titleFrame
        self.chordSymbolCase = chordSymbolCase
        self.frames = frames
        self.titleImages = titleImages
    }

    /// The boxes that touch `range` (document y), in order. A box is included when
    /// `originY + height + 1 >= range.lowerBound && originY <= range.upperBound`: the bounds are inclusive and one
    /// point of slack sits below the box, so a renderer mounting what is on screen never drops a box whose edge lies
    /// on the viewport edge.
    public func frames(inDocumentYRange range: Range<CGFloat>) -> [LayoutFrame] {
        frames.filter { $0.originY + $0.height + 1 >= range.lowerBound && $0.originY <= range.upperBound }
    }
}

extension LayoutDocument {
    /// A document containing only `systems[range]`, each system's origin shifted
    /// by `yOffset` (a negative value lifts a page's first system to y ≈ 0 so a
    /// page-mode renderer can paint page-local coordinates). `size.height` is
    /// the shifted content bound; `titleFrame` is dropped because only the first
    /// page carries it (and that page uses `yOffset == 0`).
    public func subdocument(systems range: Range<Int>, yOffset: CGFloat) -> LayoutDocument {
        let slice = systems[range].map { $0.movedBy(dy: yOffset) }
        let height = slice.map { $0.origin.y + $0.size.height }.max() ?? 0
        return LayoutDocument(
            size: CGSize(width: size.width, height: height),
            systems: slice,
            metrics: metrics,
            titleFrame: nil,
            chordSymbolCase: chordSymbolCase,
        )
    }
}
