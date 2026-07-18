import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicMIDI

/// Pluggable synth + transport backend for `PlaybackEngine`.
///
/// `PlaybackEngine` owns the backend-agnostic orchestration (master chain,
/// mixer model, `PlaybackTimeline`, cursor timer, loop-wrap decisions, state
/// machine, public API). It delegates the parts that differ between synth
/// engines — building the synth, loading a SoundFont, per-channel note / CC /
/// program delivery, and SMF-driven transport — to a `SynthBackend`.
///
/// The built-in fallback is Apple's AUMIDISynth (`AVAudioUnitMIDIInstrument` +
/// `AVAudioSequencer`), whose code stays inline in `PlaybackEngine` and is used
/// when no backend is injected. `SwiftySynthBackend` (in the
/// `SheetMusicAudioSwiftySynth` product, wrapping the pure-Swift MIT SwiftySynth)
/// fixes AUMIDISynth's voice-stealing pathology on iOS and macOS — a host
/// constructs it and injects it.
///
/// All members are `@MainActor`: the host drives transport and mixing from the
/// main actor; a backend's own audio render thread is its private concern
/// (e.g. `SwiftySynthBackend`'s `AVAudioSourceNode` render block).
@MainActor
public protocol SynthBackend: AnyObject {
    /// The single audio node the engine connects into its score-gain mixer.
    var outputNode: AVAudioNode { get }

    /// Attach the backend's node(s) to `engine` (called once, at engine build).
    func attach(to engine: AVAudioEngine)

    /// Build / reconfigure the synth for a freshly-prepared score and load
    /// `soundfontURL`. `drumChannels` are the renderer-assigned MIDI channels
    /// that should render as percussion. Called from `prepare(score:)` and
    /// again from `reloadSoundfont(...)` (with a new URL).
    func prepare(soundfontURL: URL?, drumChannels: Set<UInt8>)

    /// Load the rendered, playback-post-processed SMF into the transport.
    /// `timeline` provides tick↔seconds for backends whose transport clock is
    /// time-based (e.g. SwiftySynth) rather than tick-based.
    func loadSequence(_ midi: MidiFile, timeline: PlaybackTimeline)

    /// Load the metronome-only SMF (click track + the score's tempo map) onto
    /// the backend's separate metronome transport, kept in lockstep with the
    /// score. Muting it (`setMetronomeMuted`) is then a live flag flip — no
    /// score-SMF reload, so a toggle never resets the score synth's voices.
    func loadMetronomeSequence(_ midi: MidiFile)

    /// Silence / restore the metronome without reloading anything. The
    /// metronome transport keeps advancing while muted so an un-mute lands on
    /// the beat.
    func setMetronomeMuted(_ muted: Bool)

    /// Transport control. `currentTick` is the SMF-tick clock the cursor timer
    /// polls; `seek` and loop-wrap both move the transport in tick space.
    func play()
    func pause()
    func stop()
    func seek(toTick tick: Int)
    var currentTick: Int { get }

    /// Raw transport position in seconds on the backend's own clock, before
    /// any score-tick mapping. `currentTick` is the identity-mapped
    /// convenience (position → timeline tick); the engine reads this raw value
    /// directly when it must account for a count-in pre-roll offset the
    /// backend's loaded SMF carries but the backend itself doesn't know about.
    var currentPositionSeconds: TimeInterval { get }

    /// Playback speed multiplier (`1.0` = native tempo).
    func setRate(_ rate: Float)

    /// Whole-score tuning: `cents` is the A4 calibration offset from 440 Hz;
    /// `transposeSemitones` shifts pitched channels (drums stay at concert
    /// pitch). Persisted by the backend across sequence reloads.
    func setTuning(cents: Double, transposeSemitones: Int)

    /// Per-channel live control (mixer program / volume, tap preview).
    func setProgram(channel: UInt8, program: UInt8)
    func sendVolume(channel: UInt8, cc7: UInt8)
    func startNote(channel: UInt8, pitch: UInt8, velocity: UInt8)
    func stopNote(channel: UInt8, pitch: UInt8)

    /// Tear down synth + transport before the engine is released.
    func teardown()
}
