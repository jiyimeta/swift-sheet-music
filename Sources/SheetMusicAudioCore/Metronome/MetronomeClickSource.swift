import SheetMusicFoundation

/// Where the metronome's click sound comes from. Supplied by the host
/// through a `MetronomeClickProvider`. Kept separate from
/// `SoundfontResolver` so adding click overrides doesn't disturb the
/// score-soundfont seam.
public enum MetronomeClickSource: Sendable, Equatable, Hashable {
    /// Two WAV files (strong downbeat / weak beat). The engine converts
    /// them to an SF2 at load time via `ClickSoundFontBuilder`.
    case clickSamples(strong: URL, weak: URL)
    /// A host-supplied SoundFont, used verbatim (its bank-128 patch drives
    /// the metronome's notes 76/77).
    case soundFont(URL)
    /// Keep the current behavior: reuse the score's GM drum-kit SoundFont.
    case defaultGM
}

/// Implemented by the host to tell the engine which click sound to use.
/// Returning `.defaultGM` (or supplying no provider) preserves the legacy
/// GM drum-kit click.
public protocol MetronomeClickProvider: Sendable {
    func metronomeClickSource() -> MetronomeClickSource
}
