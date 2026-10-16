#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// Lays out a `<VBox>` or `<TBox>` that sits between systems; `nil` for the other block kinds (an HBox is
    /// horizontal room inside a system, an opaque frame has no layout). `originY` and `beforeMeasureIndex` are left
    /// at 0 for the stream placer to fill in.
    static func layoutFrame(
        _ block: ScoreBlock,
        style: ScoreStyle,
        metrics: StaffMetrics,
        docWidth: CGFloat,
        pictures: [String: Data],
    ) -> LayoutFrame? {
        // Phase A stub.
        nil
    }

    /// The pictures of a `<VBox>`, sized and placed relative to the box's top. A payload `ImageSniffer` cannot read, an
    /// SVG, or a path missing from `pictures` yields nothing. `fitHeight` is the box height an `autoScale` picture is
    /// fitted into, in points.
    static func layoutImages(
        of frame: ScoreFrame,
        pictures: [String: Data],
        docWidth: CGFloat,
        fitHeight: CGFloat,
        sp: CGFloat,
    ) -> [LayoutFrameImage] {
        // Phase A stub.
        []
    }
}
