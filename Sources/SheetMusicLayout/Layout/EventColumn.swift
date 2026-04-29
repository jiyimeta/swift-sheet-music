import CoreGraphics
import SheetMusicCore

/// One chord/rest anchor in a `LayoutSystem`, precomputed for
/// rect-range queries (`ScoreHitTester.itemIDs(in:)`) and future
/// nearest-X lookups. Coordinates are **system-relative** (same
/// space as `LayoutSystem.measures[*].elements[*]` after applying
/// the measure origin).
///
/// `staffIndex` is intentionally not stored: the spec mentioned it,
/// but the marquee query (`ScoreHitTester.itemIDs(in:)`) uses
/// `bbox.intersects(rect)` for Y-axis filtering, which already
/// segregates events by their visual row. Callers who need the
/// staff for an existing id can derive it via `id.staffIndex`
/// (`ScoreItemID.staffIndex` is a computed property).
@available(macOS 15.0, iOS 16.0, *)
public struct EventColumn: Sendable, Equatable {
    public let id: ScoreItemID
    public let voiceIndex: Int
    public let centerX: CGFloat
    public let centerY: CGFloat
    /// System-relative bbox used for rect-intersection tests.
    /// For chords this is the union of notehead rects expanded by
    /// sp * 1.2 (matches `ScoreHitTester.hitNote`'s hit radius);
    /// for rests it's a sp * 1.8 × sp * 2.5 box around origin
    /// (matches `ScoreHitTester.hitRest`'s half-extents).
    public let bbox: CGRect

    public init(
        id: ScoreItemID,
        voiceIndex: Int,
        centerX: CGFloat,
        centerY: CGFloat,
        bbox: CGRect
    ) {
        self.id = id
        self.voiceIndex = voiceIndex
        self.centerX = centerX
        self.centerY = centerY
        self.bbox = bbox
    }
}
