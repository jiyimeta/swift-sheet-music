import Foundation

/// Errors thrown by `PlaybackEngine.exportAudioFile(...)`.
///
/// `underlying: String` rather than `Error` so this stays
/// `Equatable` / `Sendable` cheaply. We render the description of
/// the original `NSError` at throw time.
public enum AudioExportError: Error, Sendable, Equatable {
    /// `prepare(score:)` has not been called for the score passed
    /// to `exportAudioFile(...)`.
    case noScorePrepared

    /// One or both cursors in `.region(...)` / `.regionThroughEnd(...)`
    /// don't resolve into the prepared score's `PlaybackTimeline`.
    case rangeNotInTimeline

    /// Format requires an OS newer than the running one (MP3 needs
    /// iOS 17 / macOS 14 / tvOS 17 / watchOS 10).
    case formatUnsupportedOnThisOS(AudioFileFormat)

    /// `AVAudioEngine.enableManualRenderingMode(...)` or
    /// `engine.start()` threw.
    case engineSetupFailed(underlying: String)

    /// `AVAudioFile` / `AVAssetWriter` write or close threw.
    case fileWriteFailed(underlying: String)

    /// `Task.checkCancellation()` fired during the render loop.
    case cancelled
}
