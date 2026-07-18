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
/// The default backend is Apple's AUMIDISynth (`AVAudioUnitMIDIInstrument` +
/// `AVAudioSequencer`), whose code stays inline in `PlaybackEngine`. An
/// alternate `FluidSynthBackend` (in the opt-in, LGPL `SheetMusicAudioFluidSynth`
/// product) fixes AUMIDISynth's voice-stealing pathology. The protocol lives in
/// this MIT module so `PlaybackEngine` never imports the LGPL backend — a host
/// that wants FluidSynth constructs it and injects it.
///
/// All members are `@MainActor`: the host drives transport and mixing from the
/// main actor; a backend's own audio render thread is its private concern
/// (e.g. `FluidSynthBackend`'s `AVAudioSourceNode` render block).
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

    /// Transport control. `currentTick` is the SMF-tick clock the cursor timer
    /// polls; `seek` and loop-wrap both move the transport in tick space.
    func play()
    func pause()
    func stop()
    func seek(toTick tick: Int)
    var currentTick: Int { get }

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
