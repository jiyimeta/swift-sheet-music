import CDirect2D

extension ScoreSurface {
    /// One overlay of `frame`, on its page: a filled shape through the shape cache, everything else walked as commands.
    func drawOverlay(_ overlay: Overlay, frame: Frame, canvas: OpaquePointer) {
        guard frame.pageOrigins.indices.contains(overlay.page) else { return }
        var walker = DrawCommandWalker(
            canvas: canvas, pxPerMM: frame.pxPerMM, offset: Self.pageOffsetPx(overlay.page, frame),
        )
        switch overlay {
        case let .fillPath(_, id, figures, argb):
            if let shape = shapes.shape(id: id, figures: figures, canvas: canvas) {
                walker.fill(shape: shape, argb: argb)
            }
        case let .clippedFillPath(_, id, figures, argb, clip):
            if let shape = shapes.shape(id: id, figures: figures, clip: clip, canvas: canvas) {
                walker.fill(shape: shape, argb: argb)
            }
        case .fillRect, .strokeRect:
            Self.paint(overlay, with: &walker)
        }
    }

    /// `overlays` painted as the surface paints them, on a white canvas `widthPx` × `heightPx` at `pxPerMM` with page
    /// 0's top-left at the origin, as BGRA premultiplied pixels, top-down — for a host's tests to compare what its
    /// overlays draw (folino checks pixel-erased ink against iOS's render). **Not supported API:** it may change or go
    /// in any release, which is why it is behind `@_spi(Testing)`.
    @_spi(Testing)
    public static func rasterizeOverlays(
        _ overlays: [Overlay], widthPx: Int, heightPx: Int, pxPerMM: Double,
    ) throws -> [UInt8] {
        try Direct2DPageRenderer.renderOverlayPixels(overlays, widthPx: widthPx, heightPx: heightPx, pxPerMM: pxPerMM)
    }

    /// One overlay through `walker`, already placed at its page, every `fillPath` built afresh. Shared with
    /// `Direct2DPageRenderer.renderOverlayPixels`, so a test reads what the surface draws.
    static func paint(_ overlay: Overlay, with walker: inout DrawCommandWalker) {
        switch overlay {
        case let .fillRect(_, rect, argb):
            walker.paint([.setColor(argb: argb), .fillRect(x: rect.x, y: rect.y, w: rect.width, h: rect.height)][...])
        case let .strokeRect(_, rect, widthMM, argb):
            walker.paint([
                .setColor(argb: argb),
                .moveTo(x: rect.x, y: rect.y), .lineTo(x: rect.maxX, y: rect.y), .lineTo(x: rect.maxX, y: rect.maxY),
                .lineTo(x: rect.x, y: rect.maxY), .lineTo(x: rect.x, y: rect.y), .stroke(width: widthMM),
            ][...])
        case let .fillPath(_, _, figures, argb):
            walker.fill(figures: figures, argb: argb)
        case let .clippedFillPath(_, _, figures, argb, clip):
            // The intersection has no per-vertex form to stream: build it, fill it, let it go.
            guard let shape = OverlayShapeCache.build(figures, clip: clip, on: walker.canvas) else { return }
            walker.fill(shape: shape, argb: argb)
            cd2d_shape_release(shape)
        }
    }
}
