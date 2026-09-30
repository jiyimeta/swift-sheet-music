import SheetMusicFoundation

/// Describes how an engine's `replaceScore(with:)` handled a prepared score.
///
/// Shared by every engine that offers the replacement (the Apple `PlaybackEngine`, the Windows
/// `WindowsPlaybackEngine`), so a host behind one protocol reads one type.
public enum ScoreReplacementOutcome: Sendable, Equatable {
    /// The score was swapped in place while keeping the synth, SoundFont,
    /// audio graph, mixer channel state, rate, tuning, transpose, master gain,
    /// and metronome state.
    case swappedInPlace

    /// The engine fell back to a full `prepare(score:)`.
    case fullyPrepared

    /// Nothing changed because an export was in flight.
    case ignoredWhileExporting
}
