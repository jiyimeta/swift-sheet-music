import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`, clashing with SheetMusicLayout's stub. Anchor
    /// to the Layout definition.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// The boxes between systems (`LayoutDocument.frames`) and the pictures of every box, in the draw program (v9).
///
/// A box after the title block is drawn as the title block is: its texts through `appendTitleFrame`, moved down to the
/// box's own top (their y is frame-local), then each picture as one `drawImage` filling the rectangle layout gave it.
/// The title block's pictures (`LayoutDocument.titleImages`) are drawn the same way, after its texts. A picture layout
/// could not size — an SVG, a payload no sniffer recognizes — never reaches `LayoutFrameImage`, so it emits nothing.
extension LayoutBridge {
    /// Emits each of `frames`: its texts, then its pictures.
    static func appendFrames(_ frames: [LayoutFrame], into out: inout [DrawCommand]) {
        for frame in frames {
            let originY = Double(frame.originY)
            appendTitleFrame(frame.content, originY: originY, into: &out)
            appendImages(frame.images, originY: originY, into: &out)
        }
    }

    /// One `drawImage` per picture, its rectangle in millimetres with `originY` (points) added to its y: a box's top
    /// for a box's pictures, whose y is relative to it, and 0 for the title block's, which are in document coordinates.
    static func appendImages(_ images: [LayoutFrameImage], originY: Double, into out: inout [DrawCommand]) {
        for image in images {
            out.append(.drawImage(
                data: image.data,
                x: Double(image.rect.minX) * ptToMMScale,
                y: (originY + Double(image.rect.minY)) * ptToMMScale,
                w: Double(image.rect.width) * ptToMMScale,
                h: Double(image.rect.height) * ptToMMScale,
            ))
        }
    }

    /// The box `frame` occupies, in millimetres, on a document `documentWidthPt` wide: the full width, from its top to
    /// its bottom. A frame's `SystemSpan` starts from it, and its commands' bounds widen it from there.
    static func frameBoxMM(_ frame: LayoutFrame, documentWidthPt: Double) -> DrawRect {
        DrawRect(
            x: 0,
            y: Double(frame.originY) * ptToMMScale,
            width: documentWidthPt * ptToMMScale,
            height: Double(frame.height) * ptToMMScale,
        )
    }
}
