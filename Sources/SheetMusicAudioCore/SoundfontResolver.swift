import SheetMusicFoundation

/// Maps a `(bank, program)` tuple to the SoundFont (.sf2) file the
/// `PlaybackEngine` should load for that voice. App authors implement
/// this to point at whatever set of `.sf2` files they're shipping or
/// downloading at runtime.
///
/// Two tiers, in priority order:
///
/// 1. `soundfontURL(forBank:program:isDrums:)` — a per-program file. These
///    are tiny (typically a few hundred KB to a few MB), so loading
///    only the patches the score actually uses keeps memory pressure
///    low — important on iPhone, where a full GM SF2 (>= ~100 MB)
///    would dominate the audio process's working set.
/// 2. `defaultGMSoundfontURL` — the full General-MIDI fallback,
///    consulted only when the per-program lookup returns `nil`.
///
/// ## `defaultGMSoundfontURL` must resolve on the Apple AUMIDISynth path
///
/// A host that does not inject a `SynthBackend` plays through Apple's
/// AUMIDISynth, and there `defaultGMSoundfontURL` returning `nil` is **not a
/// supported configuration**, however harmless "everything stays silent"
/// sounds.
///
/// Rendering an AUMIDISynth that has no real General-MIDI SoundFont loaded
/// corrupts process-wide state inside CoreAudio: the *next* AUMIDISynth in
/// that process — a later `prepare(score:)` after the user finally picks a
/// SoundFont, or an `exportAudioFile` — then faults with `EXC_BAD_ACCESS`
/// deep inside the mixer render, far from anything the host did wrong.
/// Measured on macOS 15 / Xcode 26:
///
///   * no SoundFont, or a minimal hand-built SF2, on the first synth
///     ⇒ the next synth that has a real font dies on its first render;
///   * any real GM font on the first synth ⇒ safe, *including* switching to
///     a different real font later (GeneralUser-GS ⇄ MuseScore_General both
///     ways were exercised).
///
/// So the rule is: **have a real GM `.sf2` in hand before the first
/// `prepare(score:)`.** A host that downloads or lets the user pick its
/// SoundFont should defer `prepare` until one is available rather than
/// preparing against a `nil`-returning resolver and re-preparing afterwards.
///
/// The engine does not defend against this, deliberately: the only defence
/// that works is to keep the preset-less synth out of the graph entirely, and
/// then `AVAudioSequencer` has no destination to start against — it answers
/// with `-66720`, raised as an ObjC exception no Swift `catch` can contain.
/// Trading a documented precondition for an uncatchable crash is not an
/// improvement.
///
/// Returning `nil` from *both* members is still fine for tests and for hosts
/// that never sound anything, as long as no real SoundFont is loaded later in
/// the same process.
///
/// An injected `SynthBackend` (e.g. `SwiftySynthBackend`) is unaffected — it
/// never instantiates an AUMIDISynth.
public protocol SoundfontResolver: Sendable {
    /// Resolve a `(bank, program)` to a SoundFont 2 file URL. Drum
    /// staves and metronome lookups pass `isDrums: true`; melodic
    /// staves pass `false`. Allows the host to disambiguate
    /// `(0, 0)` between Acoustic Grand Piano and the Standard Drum
    /// Kit, which the engine otherwise loads at different
    /// `bankMSB`s but identical `(bank, program)`.
    func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL?
    var defaultGMSoundfontURL: URL? { get }
}
