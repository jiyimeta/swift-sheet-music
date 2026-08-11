#if canImport(CoreGraphics)
    import CoreGraphics
#endif

public struct LayoutDocument: Sendable, Equatable {
    public let size: CGSize
    public let systems: [LayoutSystem]
    public let metrics: StaffMetrics
    /// Resolved title block for the top of the document, when the
    /// score has a leading `<VBox>`. Renderers draw this above the
    /// first system; PDF pagination treats its height as part of
    /// page 1's content budget.
    public let titleFrame: LayoutTitleFrame?

    public init(
        size: CGSize,
        systems: [LayoutSystem],
        metrics: StaffMetrics,
        titleFrame: LayoutTitleFrame? = nil,
    ) {
        self.size = size
        self.systems = systems
        self.metrics = metrics
        self.titleFrame = titleFrame
    }
}

extension LayoutDocument {
    /// A document containing only `systems[range]`, each system's origin shifted
    /// by `yOffset` (a negative value lifts a page's first system to y ≈ 0 so a
    /// page-mode renderer can paint page-local coordinates). `size.height` is
    /// the shifted content bound; `titleFrame` is dropped because only the first
    /// page carries it (and that page uses `yOffset == 0`).
    public func subdocument(systems range: Range<Int>, yOffset: CGFloat) -> LayoutDocument {
        let slice = systems[range].map { sys in
            LayoutSystem(
                origin: CGPoint(x: sys.origin.x, y: sys.origin.y + yOffset),
                size: sys.size,
                measures: sys.measures,
                staffOrigins: sys.staffOrigins,
                staffAddresses: sys.staffAddresses,
                staffGeometries: sys.staffGeometries,
                partLabels: sys.partLabels,
                brackets: sys.brackets,
                spanners: sys.spanners,
                sp: sys.sp,
                invisibleSpanners: sys.invisibleSpanners,
                showsInvisibleElements: sys.showsInvisibleElements,
            )
        }
        let height = slice.map { $0.origin.y + $0.size.height }.max() ?? 0
        return LayoutDocument(
            size: CGSize(width: size.width, height: height),
            systems: slice,
            metrics: metrics,
            titleFrame: nil,
        )
    }
}
