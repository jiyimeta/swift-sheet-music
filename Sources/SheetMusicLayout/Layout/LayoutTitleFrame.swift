import CoreGraphics
import SheetMusicCore

/// Resolved title block for a `LayoutDocument` — height in points
/// and absolute text positions ready for the renderer to consume.
/// Built by `LayoutEngine` from `Score.titleFrame`; nil when the
/// score has no leading `<VBox>`.
@available(macOS 15.0, iOS 16.0, *)
public struct LayoutTitleFrame: Sendable, Equatable {
    public let height: CGFloat
    public let texts: [LayoutFrameText]

    public init(height: CGFloat, texts: [LayoutFrameText]) {
        self.height = height
        self.texts = texts
    }
}

@available(macOS 15.0, iOS 16.0, *)
public struct LayoutFrameText: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable {
        case topLeading
        case top
        case topTrailing
        case bottomLeading
        case bottom
        case bottomTrailing
    }

    public let text: String
    public let style: FrameText.Style
    /// Center-baseline-style position within the frame, in points.
    /// Combined with `anchor` to figure out where to put the
    /// glyphs.
    public let position: CGPoint
    public let fontSize: CGFloat
    public let anchor: Anchor

    public init(
        text: String,
        style: FrameText.Style,
        position: CGPoint,
        fontSize: CGFloat,
        anchor: Anchor,
    ) {
        self.text = text
        self.style = style
        self.position = position
        self.fontSize = fontSize
        self.anchor = anchor
    }
}
