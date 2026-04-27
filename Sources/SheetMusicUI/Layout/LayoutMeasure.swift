import CoreGraphics

@available(macOS 15.0, iOS 16.0, *)
public struct LayoutMeasure: Sendable, Equatable {
    /// 0-based score-wide measure index. Identifies which measure of
    /// `score.staves[*].measures` this layout entry corresponds to,
    /// independent of the system that wrapping placed it in.
    public let measureIndex: Int
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
    /// `<LayoutBreak>line` on the source `Measure`. Render-time
    /// indicators (UI) consult this; layout has already applied
    /// the break by ending the system at this measure.
    public let lineBreak: Bool
    /// `<LayoutBreak>page` on the source `Measure`. The exporter's
    /// pagination uses this to force a page boundary; UI indicator
    /// overlay also consults it.
    public let pageBreak: Bool

    public init(
        measureIndex: Int,
        origin: CGPoint,
        width: CGFloat,
        elements: [LayoutElement],
        markers: [LayoutElement] = [],
        jumps: [LayoutElement] = [],
        lineBreak: Bool = false,
        pageBreak: Bool = false
    ) {
        self.measureIndex = measureIndex
        self.origin = origin
        self.width = width
        self.elements = elements
        self.markers = markers
        self.jumps = jumps
        self.lineBreak = lineBreak
        self.pageBreak = pageBreak
    }
}
