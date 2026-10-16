#if os(macOS)
    import AppKit
    import QuartzCore
    import SheetMusicLayout
    import SheetMusicUI

    @available(macOS 15.0, *)
    extension PDFPageLayerHostView {
        /// A page's box layers besides the title's texts, which `makeTitleTextLayer` draws: the title block's
        /// pictures, on the page that carries `titleFrame`, and each frame between systems with its texts and
        /// pictures. Each is the screen's `TitleFrameLayerBuilder` tree for a block of its own height, placed as a
        /// system is: its top at `margins.top + (documentY − pageStartY)` below the page's top, in the host's Y-up
        /// space, and its document x moved by `margins.leading`.
        static func boxLayers(
            titleFrame: LayoutTitleFrame?,
            titleImages: [LayoutFrameImage],
            frames: [LayoutFrame],
            pageStartY: CGFloat,
            pageSize: CGSize,
            margins: PageMargins,
        ) -> [CALayer] {
            let width = max(0, pageSize.width - margins.leading)
            func placed(_ layer: CALayer, top: CGFloat, height: CGFloat) -> CALayer {
                let topYUp = pageSize.height - margins.top - (top - pageStartY)
                layer.frame.origin = CGPoint(x: margins.leading, y: topYUp - height)
                return layer
            }
            var layers: [CALayer] = []
            if let titleFrame, !titleImages.isEmpty {
                // The pictures alone: the title's texts are already this view's own glyph-path layers.
                let pictures = TitleFrameLayerBuilder.build(
                    frame: LayoutTitleFrame(height: titleFrame.height, texts: []),
                    images: titleImages, width: width, height: titleFrame.height,
                )
                layers.append(placed(pictures, top: 0, height: titleFrame.height))
            }
            for box in frames {
                let layer = TitleFrameLayerBuilder.build(
                    frame: box.content, images: box.images, width: width, height: box.height,
                )
                layers.append(placed(layer, top: box.originY, height: box.height))
            }
            return layers
        }
    }
#endif
