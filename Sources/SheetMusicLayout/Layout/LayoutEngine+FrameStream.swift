#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutEngine {
    /// The frame stream (`Score.frameStream`'s VBoxes and TBoxes) laid out against the packed systems: the frames in
    /// final document coordinates, top to bottom, and per packed system the distance it moves down to make room for
    /// them (`FrameStreamPlacer`).
    static func frameStream(
        context: RenderContext,
        packed: [LayoutSystem],
    ) -> (frames: [LayoutFrame], systemShifts: [CGFloat]) {
        ([], Array(repeating: 0, count: packed.count))
    }
}
