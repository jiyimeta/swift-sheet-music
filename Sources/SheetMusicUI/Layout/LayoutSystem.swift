#if os(macOS)
import CoreGraphics

/// One horizontal line of music. Contains one or more staves stacked
/// vertically and one or more parts.
@available(macOS 15.0, *)
public struct LayoutSystem: Sendable, Equatable {
    public let origin: CGPoint       // in document coordinates
    public let size: CGSize
    public let measures: [LayoutMeasure]
    /// Per-staff baselines (top-left in system coordinates).
    public let staffOrigins: [CGPoint]
    /// Part labels at the left edge of this system (empty on continuation
    /// systems per MuseScore convention).
    public let partLabels: [LayoutPartLabel]
    /// Cross-measure spanner segments (slurs, voltas, hairpins, etc.)
    /// resolved after measure placement. Origins are in system coords.
    public let spanners: [LayoutElement]

    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        partLabels: [LayoutPartLabel],
        spanners: [LayoutElement]
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.partLabels = partLabels
        self.spanners = spanners
    }
}

@available(macOS 15.0, *)
public struct LayoutPartLabel: Sendable, Equatable {
    public let text: String
    public let origin: CGPoint

    public init(text: String, origin: CGPoint) {
        self.text = text
        self.origin = origin
    }
}
#endif
