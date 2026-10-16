#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicLayout
    import SheetMusicUI

    /// The boxes of `doc` drawn into `ctx` as `ScoreView` mounts them: the title block with its pictures
    /// (`titleImages`) at the top, and each box between systems at its `originY`, each the `TitleFrameLayerBuilder`
    /// tree the screen hosts. Placed as `renderDocumentImage` places a system: `ctx` is in points with its origin
    /// at the bitmap's bottom-left, so a Y-up tree whose top is at document `top` goes at
    /// `doc.size.height + padding − top − its height`, `padding` in from the left.
    @available(macOS 15.0, *)
    @MainActor
    func renderDocumentBoxes(_ doc: LayoutDocument, padding: CGFloat, into ctx: CGContext) {
        var boxes: [(layer: CALayer, top: CGFloat)] = []
        if let title = doc.titleFrame {
            let layer = TitleFrameLayerBuilder.build(
                frame: title, images: doc.titleImages, width: doc.size.width, height: title.height,
            )
            boxes.append((layer, 0))
        }
        for frame in doc.frames {
            let layer = TitleFrameLayerBuilder.build(
                frame: frame.content, images: frame.images, width: doc.size.width, height: frame.height,
            )
            boxes.append((layer, frame.originY))
        }
        for box in boxes {
            ctx.saveGState()
            ctx.translateBy(x: padding, y: doc.size.height + padding - box.top - box.layer.bounds.height)
            box.layer.render(in: ctx)
            ctx.restoreGState()
        }
    }
#endif
