#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// A box (`<VBox>` or `<TBox>`) laid out between two systems of the score. The leading box stays the document's
/// `titleFrame`; every box after it is one of these.
public struct LayoutFrame: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case vertical
        case text
    }

    public let kind: Kind
    /// The index of the measure the box sits before (`0` for a box between the title and the first system).
    public internal(set) var beforeMeasureIndex: Int
    /// The box's top edge in document coordinates.
    public internal(set) var originY: CGFloat
    public let height: CGFloat
    /// The box's texts: positions are frame-local in y and document x, like `LayoutDocument.titleFrame`.
    public let content: LayoutTitleFrame
    /// The box's pictures (`LayoutFrameImage.rect`: document x, y relative to this frame's top).
    public let images: [LayoutFrameImage]
    /// Whether a page break follows the box.
    public let pageBreakAfter: Bool

    /// The box's bottom edge in document coordinates.
    public var bottom: CGFloat {
        originY + height
    }
}
