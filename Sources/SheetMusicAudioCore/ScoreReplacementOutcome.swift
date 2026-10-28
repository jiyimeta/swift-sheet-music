import SheetMusicFoundation

/// Describes how an engine's `replaceScore(with:)` handled a prepared score.
///
/// Shared by every engine that offers the replacement (the Apple `PlaybackEngine`, the Windows
/// `WindowsPlaybackEngine`), so a host behind one protocol reads one type.
public enum ScoreReplacementOutcome: Sendable, Equatable {
    /// The score was swapped in place while keeping the synth, SoundFont,
    /// audio graph, mixer channel state, rate, tuning, transpose, master gain,
    /// and metronome state.
    ///
    /// On the Apple `PlaybackEngine` the mixer does take any setting the new score's own mix changed (a level saved
    /// into the score, a part's new sound); the listener's other settings stay. A host that keeps its own layer of
    /// mixer settings re-applies it after either outcome.
    case swappedInPlace

    /// The engine fell back to a full `prepare(score:)`.
    case fullyPrepared

    /// Nothing changed because an export was in flight.
    case ignoredWhileExporting
}
