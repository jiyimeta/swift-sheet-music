import SheetMusic
import SheetMusicAudio
import SheetMusicUI
import SwiftUI

/// MuseScore-convention voice highlight colors (voice 1 = blue,
/// 2 = green, 3 = orange, 4 = purple). The library ships no
/// defaults — this dictionary lives entirely in the example app
/// and is shared by both the iOS and macOS hosts.
let exampleVoiceColors: [Int: Color] = [
    0: .blue,
    1: .green,
    2: .orange,
    3: .purple,
]

extension ScoreSelection {
    /// "Play from" anchor for the current selection. For ranges
    /// and marquees `engine.earliest(of:)` decides which corner
    /// is earlier in playback time, so shift-click / drag order
    /// doesn't dictate playback start.
    @MainActor
    func playFrom(engine: PlaybackEngine) -> ScoreItemID? {
        switch self {
        case .none:
            return nil
        case let .single(id):
            return id
        case let .range(anchor, target):
            return engine.earliest(of: [anchor, target]) ?? anchor
        case let .multi(ids):
            return engine.earliest(of: Array(ids))
        }
    }
}

extension PlaybackEngine {
    /// Spacebar / play-button toggle. Reads playback start from
    /// the current cursor when present (so a paused position
    /// survives), else from the user's selection.
    ///
    /// Cursor wins over selection: a cursor left behind by the
    /// last pause is the user's "current playback position", and
    /// a stale selection from before that pause shouldn't override
    /// it. The cursor is dropped explicitly by tap handling when
    /// the user makes a NEW selection — at that point we fall
    /// through to the selection branch.
    func togglePlayback(score: Score, selection: ScoreSelection) {
        switch state {
        case .playing:
            pause()
        case .paused, .stopped:
            let from: ScoreCursor? = currentCursor
                ?? selection.playFrom(engine: self).map { .item($0) }
            play(from: from, in: score)
        }
    }
}

/// Resolve a hit-test result to its "primary" `ScoreItemID` —
/// the item the tap is conceptually pointing at. Returns `nil`
/// for misses or for beam runs that contain no notes.
func primaryItemID(of target: ScoreHitTarget?) -> ScoreItemID? {
    guard let target else { return nil }
    switch target {
    case let .note(id):
        return .note(id)
    case let .rest(id):
        return .rest(id)
    case let .stem(notes), let .flag(notes), let .beam(notes):
        return notes.first.map { .note($0) }
    case let .tuplet(id):
        return .tuplet(id)
    }
}
