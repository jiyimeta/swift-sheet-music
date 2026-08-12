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
    ///
    /// `metronomeSoundfontURL` is the click sound resolved from the host's
    /// `MetronomeClickProvider` (a generated click SF2, a host SF2, or `nil` for
    /// the GM drum-kit fallback). A backend that renders the metronome on its own
    /// synth MUST load it there when non-`nil`; passing only `soundfontURL` would
    /// click with the score font's GM wood blocks (notes 76 / 77) and silently
    /// ignore the host's click samples. It arrives here rather than through a
    /// second call so one `prepare` remains one atomic (possibly asynchronous)
    /// load.
    ///
    /// May load the SoundFont asynchronously (off the main actor) — a large
    /// General-MIDI font is tens of MB and parsing it on the main actor would
    /// freeze the UI. A backend that loads asynchronously reports `isReady ==
    /// false` until the synth lands and flips `onReadyChanged`; a backend that
    /// loads synchronously stays `isReady == true` throughout.
    ///
    /// Contract while `isReady == false`: transport / program / note / tuning
    /// commands (`loadSequence`, `seek`, `setProgram`, `startNote`, …) may be
    /// silently dropped because the synth doesn't exist yet. The engine honors
    /// this by deferring play until ready and re-asserting mixer + tuning state on
    /// the next `backendPlay`; a direct caller must await readiness before driving
    /// the transport.
    func prepare(
        soundfontURL: URL?, metronomeSoundfontURL: URL?, drumChannels: Set<UInt8>,
    )

    /// `false` while an asynchronous SoundFont load kicked by `prepare` is still
    /// in flight; `true` once the synth is playable. A synchronously-loading
    /// backend is always `true`. The engine reads this to defer a play requested
    /// mid-load until the synth is ready, and surfaces it as
    /// `PlaybackEngine.isPreparingSoundfont`.
    var isReady: Bool { get }

    /// Fired on the main actor whenever `isReady` flips. The engine installs a
    /// handler that updates `isPreparingSoundfont` and starts any play that was
    /// deferred while the SoundFont was loading.
    var onReadyChanged: (@MainActor (Bool) -> Void)? { get set }

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

    /// Whether the transport has dispatched every message of the loaded SMF —
    /// the backend's own "the piece is over" signal, in the SMF's coordinates.
    ///
    /// This is what the engine stops on, deliberately in preference to comparing
    /// a polled position against `PlaybackTimeline`. The loaded SMF is the
    /// UNROLLED render (repeats / jumps expanded) and may additionally carry a
    /// count-in pre-roll shift, while the timeline is notated and un-shifted — so
    /// any timeline-space end comparison has to reconstruct both offsets and gets
    /// it wrong on exactly the scores where it matters. The transport already
    /// knows, in its own coordinates, whether it ran out of messages.
    ///
    /// Index-based, so release tails may still be sounding when it flips, and it
    /// reads `true` before the first `play` / after a transport reset — the engine
    /// only consults it while `.playing`, which it cannot be before a `play`.
    var isAtEnd: Bool { get }

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

extension SynthBackend {
    /// Default for a backend that loads its SoundFont synchronously: it's always
    /// ready, so the engine never defers a play for it and never observes a
    /// readiness transition. A backend that loads asynchronously (e.g.
    /// `SwiftySynthBackend`) overrides both with stored properties. This keeps
    /// simple / fake backends source-compatible without boilerplate.
    public var isReady: Bool {
        true
    }

    public var onReadyChanged: (@MainActor (Bool) -> Void)? {
        get { nil }
        set { _ = newValue } // synchronous backend never fires readiness changes
    }

    /// Default for a backend with no end-of-sequence signal of its own: never
    /// reports the end, so the engine simply doesn't auto-stop it. Chosen over
    /// `true` because a wrong `true` would stop playback the moment it started,
    /// whereas a wrong `false` only leaves the host to stop it explicitly. Any
    /// backend driving a finite SMF should override this.
    public var isAtEnd: Bool {
        false
    }
}
