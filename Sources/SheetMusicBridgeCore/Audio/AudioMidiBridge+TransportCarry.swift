import SheetMusicAudioCore
import SheetMusicCore

// MARK: - Carrying the transport across a score swap

/// What the Android engine's `replaceScore` keeps across an edit: its cursor and its loop, found again in the edited
/// score at the same measure and offset (`PlaybackMeasurePosition`). The same rule the Apple engine's
/// `replaceScore(with:)` applies through the same `PlaybackTimeline` helpers, so the two cannot drift.
///
/// Both take the score BEFORE the edit as well as after it. An Android host edits the score behind the engine's handle
/// in place, so by the time it adopts the edit the "before" is gone from that handle; the engine keeps a copy of the
/// score it last prepared for exactly this (`nativeSnapshotScore`).
extension AudioMidiBridge {
    /// `cursor`, a place in `old`, as the cursor at the same measure and offset in `new` — kept inside `new` when the
    /// edit shortened it. Nil when `cursor` names nothing in `old` or `new` has no measures.
    package static func carriedCursor(_ cursor: ScoreCursor, from old: Score, to new: Score) -> ScoreCursor? {
        guard let position = PlaybackTimeline(score: old).measurePosition(ofCursor: cursor) else { return nil }
        return PlaybackTimeline(score: new).cursor(at: position)
    }

    /// The loop `range` (NOTATED ticks of `old`) as the same measures and offsets in `new`. Nil when it no longer spans
    /// anything there.
    package static func carriedLoop(_ range: LoopRange, from old: Score, to new: Score) -> LoopRange? {
        guard let loop = PlaybackTimeline(score: old).measureLoop(of: range) else { return nil }
        return PlaybackTimeline(score: new).loopRange(at: loop)
    }
}
