import SheetMusicFoundation

/// Errors raised while turning host-supplied click WAVs into a SoundFont.
///
/// A dedicated enum (rather than a new `SheetMusicError` case) keeps the
/// shared Core error type stable and avoids touching its exhaustive
/// switches.
public enum MetronomeClickError: Error, Sendable, Equatable {
    /// The bytes are not a valid PCM WAV: missing RIFF/WAVE header, no
    /// `fmt ` chunk, or no `data` chunk.
    case invalidWav(reason: String)
    /// The WAV uses a sample format the reader does not support. Only
    /// 16-bit integer PCM and 32-bit IEEE float (mono / stereo) are
    /// accepted.
    case unsupportedWavFormat(reason: String)
}
