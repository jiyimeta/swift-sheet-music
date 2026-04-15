#if os(macOS)
import CoreGraphics

@available(macOS 15.0, *)
public struct LayoutMeasure: Sendable, Equatable {
    /// Measure-local origin within its `LayoutSystem`.
    public let origin: CGPoint
    /// Width of the measure (including barline space).
    public let width: CGFloat
    /// Per-staff elements (aggregated). Origins inside `elements` are
    /// relative to the measure origin.
    public let elements: [LayoutElement]
    /// Top-left markers (segno, coda, fine, toCoda).
    public let markers: [LayoutElement]
    /// Bottom-right jumps (D.C., D.S.).
    public let jumps: [LayoutElement]

    public init(
        origin: CGPoint,
        width: CGFloat,
        elements: [LayoutElement],
        markers: [LayoutElement] = [],
        jumps: [LayoutElement] = []
    ) {
        self.origin = origin
        self.width = width
        self.elements = elements
        self.markers = markers
        self.jumps = jumps
    }
}
#endif
