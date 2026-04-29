import SheetMusicCore
import SheetMusicLayout

/// Current selection state passed to `ScoreView` for highlight rendering.
///
/// - `.none`: no notes are highlighted and no range box is drawn.
/// - `.single(NoteID)`: one note is highlighted (no range box).
/// - `.range(anchor:target:)`: every note in the rectangular region
///   bounded by `anchor` and `target` (staff × time) is highlighted,
///   and a coloured box outlines the region on each system it crosses.
public enum ScoreSelection: Sendable, Equatable {
    case none
    case single(ScoreItemID)
    case range(anchor: ScoreItemID, target: ScoreItemID)
}
