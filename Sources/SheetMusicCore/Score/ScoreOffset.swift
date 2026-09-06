/// An author-supplied engraving offset in spatium units.
///
/// This value exists instead of reusing `CGPoint` because score-model data
/// must remain portable to platforms without CoreGraphics, and its coordinates
/// are domain values measured in spatium rather than display points.
public struct ScoreOffset: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
