import AVFoundation
import Foundation
import os
import SheetMusicAudioApple
import SheetMusicAudioCore
import SheetMusicMIDI
import SwiftySynth

/// `SynthBackend` implementation backed by SwiftySynth — a pure-Swift, MIT
/// SoundFont2 synthesizer (a MeltySynth port). Being Foundation-only it runs on
/// iOS as well as macOS and is App-Store clean (unlike FluidSynth's LGPL), so it
/// is the default stealing-free backend on Apple platforms.
///
/// An `AVAudioSourceNode` pulls stereo float audio on the render thread; the
/// `MidiFileSequencer` (fed the rendered SMF) advances the transport and
/// dispatches events. SwiftySynth is **not** thread-safe, so every access to the
/// synthesizer / sequencer — from the render thread AND the main actor (mixer,
/// preview, transport) — is serialized by a single `OSAllocatedUnfairLock`.
///
/// The metronome runs on its **own** synth + sequencer (a second SMF holding
/// only the click track and the score's tempo map), mixed into the score's
/// output on the render thread. That lets the host mute / unmute it with a
/// single flag — no SMF reload, so a live toggle never resets the score synth
/// (which would cut every sounding voice). Both transports advance by the same
/// frame count each block and are seeked together, so they stay in lockstep.
@MainActor
public final class SwiftySynthBackend: SynthBackend {
    /// Everything the render thread and the main actor share. Guarded by `lock`;
    /// never touched outside `lock.withLockUnchecked`. `internal` so the render
    /// factory in `SwiftySynthBackend+Render.swift` can reach it.
    struct Shared {
        var synthesizer: Synthesizer?
        var sequencer: MidiFileSequencer?
        var metronomeSynthesizer: Synthesizer?
        var metronomeSequencer: MidiFileSequencer?
        var metronomeMuted = false
        var isPlaying = false
        /// Pre-allocated render-thread scratch for the metronome mix, so the
        /// render block allocates nothing. Sized in `prepare`.
        var scratchL: [Float] = []
        var scratchR: [Float] = []
    }

    /// The one lock serializing all SwiftySynth access. `Sendable`, so the
    /// `@Sendable` render block can capture it; the non-`Sendable` `Shared`
    /// (it holds a `Synthesizer`) lives inside it via `uncheckedState`.
    private let lock = OSAllocatedUnfairLock(uncheckedState: Shared())

    /// Render-thread scratch capacity (frames). Larger caller chunks are mixed
    /// in `scratchCapacity`-frame slices, so any `frameCount` is handled.
    static let scratchCapacity = 4096

    private let sampleRate: Double
    /// Tick↔seconds for the loaded score (SwiftySynth's clock is seconds).
    private var timeline: PlaybackTimeline?

    // Persisted transport/tuning state, re-applied whenever the synth or
    // sequence is rebuilt (both reset SwiftySynth's channel/speed state).
    private var rate: Float = 1
    private var tuningCents: Double = 0
    private var transposeSemitones = 0

    public let sourceNode: AVAudioSourceNode
    public var outputNode: AVAudioNode {
        sourceNode
    }

    public init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        sourceNode = Self.makeSourceNode(lock: lock, sampleRate: sampleRate)
    }

    // MARK: SynthBackend

    public func attach(to engine: AVAudioEngine) {
        engine.attach(sourceNode)
    }

    public func prepare(soundfontURL: URL?, drumChannels _: Set<UInt8>) {
        // SwiftySynth resolves percussion on MIDI channel 9 automatically
        // (`Synthesizer.percussionChannel`), so `drumChannels` is unused.
        // The metronome plays GM wood blocks (76 / 77) on channel 9 through a
        // second synth SHARING the score's SoundFont, so its sound matches the
        // score's percussion exactly at no extra load cost. That synth runs
        // reverb/chorus OFF with a tiny voice pool — clicks need neither — so
        // it adds almost no per-block DSP, which matters on CPU-tight
        // lightweight SoundFonts where the constant cost of an always-on
        // effects chain could otherwise miss the render deadline.
        let soundFont: SoundFont? = soundfontURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? SoundFont(data: $0) }
        let score = Self.makeSynth(
            soundFont: soundFont, sampleRate: sampleRate,
            maximumPolyphony: 256, enableReverbAndChorus: true,
        )
        let metronome = Self.makeSynth(
            soundFont: soundFont, sampleRate: sampleRate,
            maximumPolyphony: 8, enableReverbAndChorus: false,
        )
        lock.withLockUnchecked { shared in
            shared.synthesizer = score?.synth
            shared.sequencer = score?.sequencer
            shared.metronomeSynthesizer = metronome?.synth
            shared.metronomeSequencer = metronome?.sequencer
            shared.isPlaying = false
            if shared.scratchL.count != Self.scratchCapacity {
                shared.scratchL = [Float](repeating: 0, count: Self.scratchCapacity)
                shared.scratchR = [Float](repeating: 0, count: Self.scratchCapacity)
            }
        }
        applyRateAndTuning()
    }

    /// Build a `Synthesizer` + its `MidiFileSequencer` from an already-loaded
    /// `SoundFont`. Returns nil if `soundFont` is nil or the synth can't build.
    private nonisolated static func makeSynth(
        soundFont: SoundFont?, sampleRate: Double,
        maximumPolyphony: Int, enableReverbAndChorus: Bool,
    ) -> (synth: Synthesizer, sequencer: MidiFileSequencer)? {
        guard let soundFont,
              let settings = try? SynthesizerSettings(
                  sampleRate: Int(sampleRate),
                  maximumPolyphony: maximumPolyphony,
                  enableReverbAndChorus: enableReverbAndChorus,
              ),
              let synth = try? Synthesizer(soundFont: soundFont, settings: settings)
        else { return nil }
        return (synth, MidiFileSequencer(synthesizer: synth))
    }

    public func loadSequence(_ midi: SheetMusicMIDI.MidiFile, timeline: PlaybackTimeline) {
        self.timeline = timeline
        guard let smf = Self.parse(midi) else { return }
        lock.withLockUnchecked { shared in
            shared.sequencer?.play(smf, loop: false)
            shared.isPlaying = false
        }
        // `sequencer.play` resets the synthesizer, so re-assert rate + tuning.
        applyRateAndTuning()
    }

    public func loadMetronomeSequence(_ midi: SheetMusicMIDI.MidiFile) {
        guard let smf = Self.parse(midi) else { return }
        lock.withLockUnchecked { shared in
            shared.metronomeSequencer?.play(smf, loop: false)
            shared.metronomeSequencer?.speed = max(0.01, Double(rate))
        }
    }

    public func setMetronomeMuted(_ muted: Bool) {
        lock.withLockUnchecked { shared in
            // Un-muting: the metronome transport froze while muted (not
            // rendered, to spend no CPU), so reseek it to the score's current
            // position before it resumes so clicks land back on the beat.
            if !muted, shared.metronomeMuted, let pos = shared.sequencer?.position {
                shared.metronomeSequencer?.seek(to: pos)
            }
            shared.metronomeMuted = muted
        }
    }

    private nonisolated static func parse(_ midi: SheetMusicMIDI.MidiFile) -> SwiftySynth.MidiFile? {
        guard let bytes = try? MidiWriter.write(midi),
              let smf = try? SwiftySynth.MidiFile(data: bytes)
        else { return nil }
        return smf
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        let speed = max(0.01, Double(rate))
        lock.withLockUnchecked { shared in
            shared.sequencer?.speed = speed
            shared.metronomeSequencer?.speed = speed
        }
    }

    public func setTuning(cents: Double, transposeSemitones: Int) {
        tuningCents = cents
        self.transposeSemitones = transposeSemitones
        lock.withLockUnchecked { shared in
            if let synthesizer = shared.synthesizer {
                Self.applyTuning(
                    to: synthesizer, cents: cents,
                    transposeSemitones: transposeSemitones,
                )
            }
        }
    }

    private func applyRateAndTuning() {
        let speed = max(0.01, Double(rate))
        lock.withLockUnchecked { shared in
            shared.sequencer?.speed = speed
            shared.metronomeSequencer?.speed = speed
            if let synthesizer = shared.synthesizer {
                Self.applyTuning(
                    to: synthesizer, cents: tuningCents,
                    transposeSemitones: transposeSemitones,
                )
            }
        }
    }

    /// Apply whole-score tuning via standard RPN messages: RPN 1 (fine tune) =
    /// the A4 `cents` offset on every channel; RPN 2 (coarse tune) =
    /// `transposeSemitones` on pitched channels, neutral on drums (ch 9). Ends
    /// with an RPN-null deselect so a later data-entry can't clobber the value.
    /// Applied to the score synth only — the metronome stays at concert pitch.
    private nonisolated static func applyTuning(
        to synthesizer: Synthesizer, cents: Double, transposeSemitones: Int,
    ) {
        let coarse = max(0, min(127, 64 + transposeSemitones))
        let fine14 = max(0, min(16383, 8192 + Int((cents / 100.0) * 8192.0)))
        func cc(_ channel: Int, _ controller: Int, _ value: Int) {
            synthesizer.processMidiMessage(
                channel: channel, command: 0xB0, data1: controller, data2: value,
            )
        }
        for channel in 0 ..< 16 {
            // RPN 1: fine tune (cents) — every channel.
            cc(channel, 101, 0); cc(channel, 100, 1)
            cc(channel, 6, (fine14 >> 7) & 0x7F)
            cc(channel, 38, fine14 & 0x7F)
            // RPN 2: coarse tune (semitones) — pitched channels only.
            cc(channel, 101, 0); cc(channel, 100, 2)
            cc(channel, 6, channel == Synthesizer.percussionChannel ? 64 : coarse)
            // RPN null (deselect).
            cc(channel, 101, 127); cc(channel, 100, 127)
        }
    }

    public func play() {
        lock.withLockUnchecked { $0.isPlaying = true }
    }

    public func pause() {
        lock.withLockUnchecked { $0.isPlaying = false }
    }

    public func stop() {
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.sequencer?.seek(to: .zero)
            shared.synthesizer?.noteOffAll(immediate: true)
            shared.metronomeSequencer?.seek(to: .zero)
            shared.metronomeSynthesizer?.noteOffAll(immediate: true)
        }
    }

    public func seek(toTick tick: Int) {
        guard let timeline else { return }
        // Seek a half-tick BEFORE the target onset. `MidiFileSequencer.seek`
        // chases — and drops — every note-on strictly before its target
        // seconds, so the note that starts exactly at `tick` must land at or
        // after the seek point to be played. But `timeline`'s tick→seconds
        // clock and SwiftySynth's own SMF-integration clock are independent
        // `Double` accumulations that differ by a few ULPs whose sign varies
        // per note; when the note lands an ULP before `seconds(atTick: tick)`
        // it would be silently skipped. Backing off by half a tick (≫ any
        // inter-clock rounding skew, yet ≪ the ≥1-tick gap to any distinct
        // earlier onset) makes the target note play deterministically without
        // ever pulling in the previous one. The engine still pins the cursor
        // to `tick` itself, so the displayed position is unaffected.
        let seconds = timeline.seconds(atTick: Double(tick) - 0.5)
        lock.withLockUnchecked { shared in
            shared.sequencer?.seek(to: .seconds(seconds))
            shared.metronomeSequencer?.seek(to: .seconds(seconds))
        }
    }

    public var currentPositionSeconds: TimeInterval {
        lock.withLockUnchecked { shared -> Double in
            guard let pos = shared.sequencer?.position else { return 0 }
            return Double(pos.components.seconds)
                + Double(pos.components.attoseconds) * 1e-18
        }
    }

    public var currentTick: Int {
        guard let timeline else { return 0 }
        return timeline.frame(atTime: currentPositionSeconds)?.tick ?? 0
    }

    public func setProgram(channel: UInt8, program: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.processMidiMessage(
                channel: Int(channel), command: 0xC0, data1: Int(program), data2: 0,
            )
        }
    }

    public func sendVolume(channel: UInt8, cc7: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.processMidiMessage(
                channel: Int(channel), command: 0xB0, data1: 7, data2: Int(cc7),
            )
        }
    }

    public func startNote(channel: UInt8, pitch: UInt8, velocity: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.noteOn(key: Int(pitch), velocity: Int(velocity), on: Int(channel))
        }
    }

    public func stopNote(channel: UInt8, pitch: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.noteOff(key: Int(pitch), on: Int(channel))
        }
    }

    public func teardown() {
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.sequencer?.stop()
            shared.metronomeSequencer?.stop()
            shared.sequencer = nil
            shared.synthesizer = nil
            shared.metronomeSequencer = nil
            shared.metronomeSynthesizer = nil
        }
    }
}
