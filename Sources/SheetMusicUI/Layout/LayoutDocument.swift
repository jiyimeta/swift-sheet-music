import CoreGraphics

@available(macOS 15.0, iOS 16.0, *)
public struct LayoutDocument: Sendable, Equatable {
    public let size: CGSize
    public let systems: [LayoutSystem]
    public let metrics: StaffMetrics

    public init(
        size: CGSize,
        systems: [LayoutSystem],
        metrics: StaffMetrics
    ) {
        self.size = size
        self.systems = systems
        self.metrics = metrics
    }
}
