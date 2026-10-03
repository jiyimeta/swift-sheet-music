import CDirect2D

extension ScoreSurface {
    /// One overlay of `frame`, on its page: a filled shape through the shape cache, everything else walked as commands.
    func drawOverlay(_ overlay: Overlay, frame: Frame, canvas: OpaquePointer) {
        guard frame.pageOrigins.indices.contains(overlay.page) else { return }
        var walker = DrawCommandWalker(
            canvas: canvas, pxPerMM: frame.pxPerMM, offset: Self.pageOffsetPx(overlay.page, frame),
        )
        if case let .fillPath(_, id, figures, argb) = overlay {
            if let shape = shapes.shape(id: id, figures: figures, canvas: canvas) {
                walker.fill(shape: shape, argb: argb)
            }
            return
        }
        Self.paint(overlay, with: &walker)
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
        }
    }
}
