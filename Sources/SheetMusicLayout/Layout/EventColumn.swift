import CoreGraphics
import SheetMusicCore

/// One chord/rest anchor in a `LayoutSystem`, precomputed for
/// rect-range queries (`ScoreHitTester.itemIDs(in:)`) and future
/// nearest-X lookups. Coordinates are **system-relative** (same
/// space as `LayoutSystem.measures[*].elements[*]` after applying
/// the measure origin).
@available(macOS 15.0, iOS 16.0, *)
public struct EventColumn: Sendable, Equatable {
    public let id: ScoreItemID
    public let voiceIndex: Int
    public let centerX: CGFloat
    public let centerY: CGFloat
    /// System-relative bbox used for rect-intersection tests.
    /// For chords this is the union of notehead rects; for rests
    /// it's the rest glyph rect (matches `ScoreHitTester.hitRest`'s
    /// half-extents: 1.8 sp × 2.5 sp around `origin`).
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
