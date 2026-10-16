#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// One picture of a mid-score box (or of the leading box, in `LayoutDocument.titleImages`), already sized and placed.
///
/// `rect`'s x is a document x. Its y is relative to the owning frame's top, like the texts of `LayoutFrame.content`;
/// for `LayoutDocument.titleImages` both are document coordinates (margins included). The bytes travel with the
/// geometry so a renderer needs no side table.
public struct LayoutFrameImage: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        case png
        case jpeg
    }

    public let data: Data
    public let format: Format
    public let rect: CGRect
}
