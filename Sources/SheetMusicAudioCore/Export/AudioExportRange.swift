import SheetMusicCore

/// What region of the score to export to audio.
///
/// `.full`               — entire score (default).
/// `.currentLoop`        — `PlaybackEngine.loopRange` if set, else falls
///                         back to `.full`.
/// `.region`             — half-open `[from, to)` cursor range.
/// `.regionThroughEnd`   — like `.region`, but extends through the
///                         full duration of `last` so its trailing
///                         ring is included.
public enum AudioExportRange: Sendable {
    case full
    case currentLoop
    case region(from: ScoreCursor, to: ScoreCursor)
    case regionThroughEnd(from: ScoreCursor, last: ScoreItemID)
}
