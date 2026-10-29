// swiftlint:disable file_length
// The async-load + full transport/mixer surface makes this backend inherently
// large; its render factory already lives in `SwiftySynthBackend+Render.swift`.
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
        /// Linear gain applied to the metronome mix. Lives here rather than on
        /// the class because the render block reads it; it survives a `prepare`
        /// (which resets only the synth / sequencer fields), so the host's strip
        /// volume outlives a SoundFont swap without being re-pushed.
        var metronomeGain: Float = 1
        var isPlaying = false
        /// Frames of count-in pre-roll still owed. While it is `> 0` the SCORE
        /// transport is held (only its release tails render) and the metronome
        /// transport advances AND sounds regardless of `metronomeMuted` — the
        /// count has to be audible with the metronome switched off, which is the
        /// usual case. Decremented on the render thread, so the body starts on
        /// the exact frame the count ends.
        var preRollFramesRemaining = 0
        /// Seconds the metronome transport runs AHEAD of the score transport.
        /// Non-zero only for a count-in sequence, whose SMF carries a pre-roll
        /// the score's does not; added to every metronome seek so the two stay
        /// aligned for the rest of the playback.
        var metronomeOffsetSeconds: Double = 0
        /// Pre-allocated render-thread scratch for the metronome mix, so the
        /// render block allocates nothing. Sized in `prepare`.
        var scratchL: [Float] = []
        var scratchR: [Float] = []
        /// The speed table both transports follow, the recordings mixed on them and the render thread's block
        /// bookkeeping (`SwiftySynthBackend+Recordings.swift`). Survives a `prepare`, like `metronomeGain`.
        var alignment = PlaybackAlignmentState()
    }

    /// The one lock serializing all SwiftySynth access. `Sendable`, so the
    /// `@Sendable` render block can capture it; the non-`Sendable` `Shared`
    /// (it holds a `Synthesizer`) lives inside it via `uncheckedState`.
    /// `internal` so `SwiftySynthBackend+Recordings.swift` can swap its tables in.
    let lock = OSAllocatedUnfairLock(uncheckedState: Shared())

    /// Render-thread scratch capacity (frames). Larger caller chunks are mixed
    /// in `scratchCapacity`-frame slices, so any `frameCount` is handled.
    static let scratchCapacity = 4096

    /// The rate every `Synthesizer` this backend builds renders at, fixed at
    /// init. `internal` (not `private`) only so a test can assert that
    /// `makeOfflineInstance` honors the export's requested rate — an unattached
    /// `AVAudioNode` reports the hardware format, not the one it was built with,
    /// so the node itself can't answer that.
    let sampleRate: Double
    /// Tick↔seconds for the loaded score (SwiftySynth's clock is seconds).
    private var timeline: PlaybackTimeline?
    /// Projection between `timeline`'s NOTATED clock and the loaded SMF's UNROLLED one. Identity
    /// until the engine supplies it (`setUnrolledTimeMap`), and identity for any score whose
    /// repeats aren't expanded — which is why every conversion below reads the same either way.
    private var unrolledTimeMap: UnrolledTimeMap = .identity

    /// Where the last `seek(toTick:)` parked the transport (clamped at 0, as the sequencer clamps it) and the onset it
    /// parked before, both on the unrolled clock. A count-in reads its speed at that onset
    /// (`play(afterCountInSeconds:)`).
    private var lastPark: (parked: TimeInterval, onset: TimeInterval)?

    // Persisted transport/tuning state, re-applied whenever the synth or
    // sequence is rebuilt (both reset SwiftySynth's channel/speed state).
    // `rate` is internal so `SwiftySynthBackend+Recordings.swift` can tell which groups need a stretcher.
    var rate: Float = 1
    private var tuningCents: Double = 0
    private var transposeSemitones = 0

    // MARK: Off-main SoundFont load

    /// Bumped on every `prepare` (and `teardown`). A background load applies its
    /// result only if the generation still matches, so a superseded reload — or a
    /// teardown — can't clobber the current synth with a stale one.
    private var loadGeneration = 0

    /// `false` while a background SoundFont load kicked by `prepare` is in flight.
    /// The engine reads this to defer a play until the synth is ready.
    public private(set) var isReady = true

    /// Fired on the main actor whenever `isReady` flips (see `SynthBackend`).
    public var onReadyChanged: (@MainActor (Bool) -> Void)?

    /// The in-flight background load, cancelled by a superseding `prepare` /
    /// `teardown` so a rapid SoundFont swap doesn't run two full ~200 MB loads at
    /// once (transient-memory / jetsam pressure on constrained devices).
    private var loadTask: Task<Void, Never>?

    /// The freshly-built synths handed back from the background load. Non-`Sendable`
    /// SwiftySynth types cross the actor boundary here, but safely: they are built
    /// inside the detached task and never touched until this hand-off installs them
    /// under `lock`, so the transfer is a move, not sharing.
    private struct LoadedSynths: @unchecked Sendable {
        let score: (synth: Synthesizer, sequencer: MidiFileSequencer)?
        let metronome: (synth: Synthesizer, sequencer: MidiFileSequencer)?
        let scoreFont: SoundFontCache.Loaded?
    }

    // MARK: Sample prefetch (`SwiftySynthBackend+Prefetch.swift`)

    /// The score synth's font, kept so the instruments a sequence plays can be read in ahead of the render thread.
    var scoreSoundFont: SoundFontCache.Loaded?
    /// The presets the loaded sequence sounds, read in again whenever a new score font lands.
    var sequencePresets: Set<PlayedPreset> = []
    /// Bumped per loaded sequence, so a slow scan of an older sequence cannot overwrite a newer one's presets.
    var sequencePresetGeneration = 0

    public let sourceNode: AVAudioSourceNode
    public var outputNode: AVAudioNode {
        sourceNode
    }

    /// What makes the stretchers recordings are read through when the rate is not 100 % or a track is transposed. Nil:
    /// recordings are read directly at any rate (varispeed) and their transposition is ignored.
    let stretcherFactory: RecordingStretcherFactory?
    /// The main actor's copy of `Shared.alignment.groups`' layout and pairs (`SwiftySynthBackend+Recordings.swift`).
    var recordingGroupLayout: [RecordingGroupLayout] = []
    /// The main actor's copy of the groups left draining after the track list dropped them; in the render's array they
    /// follow `recordingGroupLayout`'s.
    var drainingGroupLayout: [RecordingGroupLayout] = []
    /// The input capacity of the stretch scratch handed to the render thread, 0 before the first.
    var stretchScratchCapacity = 0

    public init(sampleRate: Double = 44100, stretcherFactory: RecordingStretcherFactory? = nil) {
        self.sampleRate = sampleRate
        self.stretcherFactory = stretcherFactory
        sourceNode = Self.makeSourceNode(lock: lock, sampleRate: sampleRate)
    }

    // MARK: SynthBackend

    public func attach(to engine: AVAudioEngine) {
        engine.attach(sourceNode)
    }

    public func prepare(
        soundfontURL: URL?, metronomeSoundfontURL: URL?, drumChannels _: Set<UInt8>,
    ) {
        // SwiftySynth resolves percussion on MIDI channel 9 automatically
        // (`Synthesizer.percussionChannel`), so `drumChannels` is unused.
        // The metronome plays notes 76 / 77 on channel 9 through a second synth.
        // That synth loads `metronomeSoundfontURL` — the host's click sound,
        // resolved by `MetronomeClickResolver` — and only falls back to SHARING
        // the score's SoundFont (GM wood blocks) when the host supplies none.
        // Sharing unconditionally is what made a host-supplied click inaudible
        // during playback while offline export, which then rendered the
        // metronome on AUMIDISynth, still used it. That synth runs reverb/chorus OFF with a
        // tiny voice pool — clicks need neither — so it adds almost no per-block
        // DSP, which matters on CPU-tight lightweight SoundFonts where the
        // constant cost of an always-on effects chain could otherwise miss the
        // render deadline.
        //
        // The SoundFont read + parse + synth build runs OFF the main actor: a
        // General-MIDI font is tens of MB (the high-quality one is ~200 MB), and
        // doing that work synchronously on the main actor froze the UI for
        // seconds. While the load is in flight `isReady` is false, the render
        // block emits silence (its `shared.synthesizer` is nil), and the engine
        // defers any play; the freshly-built synths are swapped in under `lock`
        // the moment they land (`applyLoaded`).
        loadGeneration += 1
        let generation = loadGeneration
        setReady(false)
        loadTask?.cancel()
        // Drop the old synth so the render block goes silent until the new one lands.
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.alignment.sequencerRepositioned()
            shared.alignment.silenceRecordings()
            shared.synthesizer = nil
            shared.sequencer = nil
            shared.metronomeSynthesizer = nil
            shared.metronomeSequencer = nil
            if shared.scratchL.count != Self.scratchCapacity {
                shared.scratchL = [Float](repeating: 0, count: Self.scratchCapacity)
                shared.scratchR = [Float](repeating: 0, count: Self.scratchCapacity)
            }
        }
        scoreSoundFont = nil
        let sampleRate = sampleRate
        // `Task.detached` guarantees the heavy read/parse/build runs off the main
        // actor regardless of the caller-isolation default; cheap `isCancelled`
        // checkpoints bracket the expensive work so a superseded swap bails before
        // building the ~200 MB synth pair. The build hands the (non-Sendable)
        // synths back to the main actor via `install`, boxed as `LoadedSynths`.
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            /// Through `SoundFontCache`: a font another backend already has loaded — live playback while an export
            /// renders, or several part renders at once — is the same parse.
            func read(_ url: URL?) async -> SoundFontCache.Loaded? {
                guard let url else { return nil }
                return await SoundFontCache.shared.soundFont(at: url)
            }
            let scoreFont = await read(soundfontURL)
            let soundFont = scoreFont?.font
            if Task.isCancelled { return }
            // A generated click SF2 is a few tens of KB, so the extra parse is
            // negligible next to the score font. Falling back to `soundFont`
            // keeps the shared-font behavior for `.defaultGM` hosts and for a
            // click font that fails to parse.
            let clickFont = await metronomeSoundfontURL == soundfontURL
                ? soundFont
                : (read(metronomeSoundfontURL)?.font ?? soundFont)
            if Task.isCancelled { return }
            let loaded = LoadedSynths(
                score: Self.makeSynth(
                    soundFont: soundFont, sampleRate: sampleRate,
                    maximumPolyphony: 256, enableReverbAndChorus: true,
                ),
                metronome: Self.makeSynth(
                    soundFont: clickFont, sampleRate: sampleRate,
                    maximumPolyphony: 8, enableReverbAndChorus: false,
                ),
                scoreFont: scoreFont,
            )
            await self?.install(loaded, generation: generation)
        }
    }

    /// Main-actor hand-off from the background load: install the built synths
    /// unless a newer `prepare` / `teardown` (or this task's own cancellation) has
    /// superseded this generation.
    private func install(_ loaded: LoadedSynths, generation: Int) {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        applyLoaded(loaded)
    }

    /// Install a completed background load and re-assert the persisted rate /
    /// tuning (a fresh synth resets both), then flip `isReady` so the engine can
    /// run any play it deferred while the SoundFont was loading.
    private func applyLoaded(_ loaded: LoadedSynths) {
        lock.withLockUnchecked { shared in
            shared.synthesizer = loaded.score?.synth
            shared.sequencer = loaded.score?.sequencer
            shared.metronomeSynthesizer = loaded.metronome?.synth
            shared.metronomeSequencer = loaded.metronome?.sequencer
        }
        scoreSoundFont = loaded.scoreFont
        // A sequence loaded while the font was still loading has its presets recorded but not yet read in.
        prefetchInBackground(sequencePresets)
        applyRateAndTuning()
        setReady(true)
    }

    /// Set `isReady` and notify the host. Fires unconditionally (not guarded on a
    /// value change) so a `prepare` right after a `teardown` — which left
    /// `isReady` false without notifying — still signals "preparing"; a redundant
    /// same-value notification is harmless (the engine's handler is idempotent).
    private func setReady(_ ready: Bool) {
        isReady = ready
        onReadyChanged?(ready)
    }

    /// Build a `Synthesizer` + its `MidiFileSequencer` from an already-loaded
    /// `SoundFont`. Returns nil if `soundFont` is nil or the synth can't build.
    private nonisolated static func makeSynth(
        soundFont: SoundFont?, sampleRate: Double,
        maximumPolyphony: Int, enableReverbAndChorus: Bool,
    ) -> (synth: Synthesizer, sequencer: MidiFileSequencer)? {
        guard let soundFont,
              // Enable SF2 note-on modulators (swiftysynth 0.2.0+): fonts that voice a
              // preset via velocity→attenuation/filter modulators (e.g. MuseScore_General's
              // Acoustic Grand Piano) render at their intended level instead of near-silent.
              let settings = try? SynthesizerSettings(
                  sampleRate: Int(sampleRate),
                  maximumPolyphony: maximumPolyphony,
                  enableReverbAndChorus: enableReverbAndChorus,
                  enableModulators: true,
              ),
              let synth = try? Synthesizer(soundFont: soundFont, settings: settings)
        else { return nil }
        // SwiftySynth inherits MeltySynth's C# field initializer of 0.5 here, which is a
        // porting artifact rather than a considered default — it costs a flat 6 dB against
        // the host's own gain stage for no reason. The engine already owns level control
        // (`scoreGainMixer` / `setMasterGain`), so the synth should hand back unity and let
        // that stage decide. Measured: 0.5 → 1.0 recovers exactly 6.02 dB on a single voice.
        //
        // This does NOT close the whole gap against the old AUMIDISynth path, which measured
        // ~20 dB louder — but that path peaked at +2.17 dBFS on ONE note, i.e. it was clipping
        // and leaning on the master limiter. Matching it would mean reproducing distortion, so
        // the rest is deliberately left to the host's master volume.
        synth.masterVolume = 1.0
        return (synth, MidiFileSequencer(synthesizer: synth))
    }

    public func setUnrolledTimeMap(_ map: UnrolledTimeMap) {
        unrolledTimeMap = map
    }

    public func loadSequence(_ midi: SheetMusicMIDI.MidiFile, timeline: PlaybackTimeline) {
        self.timeline = timeline
        guard let smf = Self.parse(midi) else { return }
        lock.withLockUnchecked { shared in
            shared.sequencer?.play(smf, loop: false)
            shared.isPlaying = false
            shared.preRollFramesRemaining = 0
            shared.alignment.sequencerRepositioned()
            shared.alignment.silenceRecordings()
        }
        // `sequencer.play` resets the synthesizer, so re-assert rate + tuning.
        applyRateAndTuning()
        prefetchPresets(of: midi)
    }

    public func loadMetronomeSequence(
        _ midi: SheetMusicMIDI.MidiFile, offsetSeconds: TimeInterval = 0,
    ) {
        guard let smf = Self.parse(midi) else { return }
        lock.withLockUnchecked { shared in
            // `play` parks the transport at 0 — the pre-roll's first click for a
            // count-in sequence, the score's own start for a plain one.
            shared.metronomeSequencer?.play(smf, loop: false)
            shared.metronomeSequencer?.speed = max(0.01, Double(rate))
            shared.metronomeOffsetSeconds = offsetSeconds
        }
    }

    public func setMetronomeMuted(_ muted: Bool) {
        lock.withLockUnchecked { shared in
            let wasFrozen = Self.metronomeIsFrozen(shared)
            shared.metronomeMuted = muted
            Self.resyncMetronome(ifThawedFrom: wasFrozen, &shared)
        }
    }

    public func setMetronomeVolume(_ volume: Float) {
        lock.withLockUnchecked { shared in
            let wasFrozen = Self.metronomeIsFrozen(shared)
            shared.metronomeGain = max(0, volume)
            Self.resyncMetronome(ifThawedFrom: wasFrozen, &shared)
        }
    }

    /// Whether the render block skips the metronome — muted, or at zero gain — so that it costs no CPU. Its transport
    /// does not advance meanwhile.
    private nonisolated static func metronomeIsFrozen(_ shared: Shared) -> Bool {
        shared.metronomeMuted || shared.metronomeGain <= 0
    }

    /// When the metronome becomes audible again — un-muted, or turned up from zero — reseek its frozen transport to
    /// the score's current position, so clicks land back on the beat. Zero gain used to freeze it exactly as a mute
    /// does without ever reseeking it, so turning the click down to nothing and back up mid-playback left every later
    /// click late by however long it had been silent.
    private nonisolated static func resyncMetronome(ifThawedFrom wasFrozen: Bool, _ shared: inout Shared) {
        guard wasFrozen, !metronomeIsFrozen(shared), let pos = shared.sequencer?.position else { return }
        let seconds = Double(pos.components.seconds) + Double(pos.components.attoseconds) * 1e-18
        shared.metronomeSequencer?.seek(to: metronomePosition(seconds, in: shared))
    }

    /// Where the metronome transport belongs when the score transport is at
    /// `seconds`. Clamped at zero: with a count-in started mid-score the offset
    /// is negative (the count is shorter than the music already behind the start
    /// position), and a host that then seeks back near the top would otherwise
    /// ask for a position before the sequence begins.
    private nonisolated static func metronomePosition(
        _ seconds: Double, in shared: Shared,
    ) -> Duration {
        .seconds(max(0, seconds + shared.metronomeOffsetSeconds))
    }

    private nonisolated static func parse(_ midi: SheetMusicMIDI.MidiFile) -> SwiftySynth.MidiFile? {
        guard let bytes = try? MidiWriter.write(midi),
              let smf = try? SwiftySynth.MidiFile(data: bytes)
        else { return nil }
        return smf
    }

    /// Under a warp the speed written here is the unstretched one, but it never reaches a block: the sequencer applies
    /// a speed only at a block start, and the render sets the stretched one there first.
    ///
    /// A rate away from 100 % makes the stretcher pairs the recordings now need, here on the main actor; they are
    /// kept when the rate comes back, so a tempo drag makes them once.
    public func setRate(_ rate: Float) {
        self.rate = rate
        let speed = max(0.01, Double(rate))
        let stretchers = stretchersForRate()
        var scratch = stretchers.scratch
        lock.withLockUnchecked { shared in
            shared.alignment.userSpeed = speed
            shared.sequencer?.speed = speed
            shared.metronomeSequencer?.speed = speed
            Self.installStretchers(stretchers.pairs, scratch: &scratch, into: &shared)
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
            shared.alignment.userSpeed = speed
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
        lock.withLockUnchecked { shared in
            shared.preRollFramesRemaining = 0
            shared.isPlaying = true
        }
    }

    /// Under a warp the count runs at the speed of the measure it counts into — `seconds` are the metronome SMF's, so
    /// it lasts `seconds / speed` — and keeps that speed to its end, a table swap during it applying from the body on.
    /// Without a warp the count's length and speed are what they always were. The rule is
    /// `TransportSpeedTable.countIn(seconds:userSpeed:bodyStart:)`, which an export's length reads too, from the same
    /// onset.
    public func play(afterCountInSeconds seconds: TimeInterval) {
        let sampleRate = sampleRate
        let lastPark = lastPark
        lock.withLockUnchecked { shared in
            var countIn: (duration: TimeInterval, speed: Double?) = (seconds, nil)
            if let sequencer = shared.sequencer {
                let position = sequencer.position.components
                let held = shared.alignment.transportSeconds(
                    quantized: Double(position.seconds) + Double(position.attoseconds) * 1e-18,
                    sampleRate: sampleRate, blockSize: sequencer.synthesizer.blockSize,
                )
                // The body starts at the onset the last seek parked before, while the transport still waits there;
                // where it waits is half a tick earlier, which at a slow tempo is still the measure before.
                let onset = lastPark.flatMap { abs($0.parked - held) < 1e-9 ? $0.onset : nil }
                countIn = shared.alignment.speedTable.countIn(
                    seconds: seconds, userSpeed: shared.alignment.userSpeed, bodyStart: onset ?? held,
                )
            }
            shared.alignment.countInSpeed = countIn.speed
            shared.preRollFramesRemaining = max(0, Int((countIn.duration * sampleRate).rounded()))
            shared.isPlaying = true
        }
    }

    /// Ends the sounding voices as well as holding the transport — see `SynthBackend.pause()` for why a pause that
    /// only stops the clock is heard later as a chord underneath the next note preview.
    ///
    /// Both synthesizers, because a count-in click can be mid-decay at a pause exactly as a chord can, and
    /// `immediate: true` rather than a release: the host pauses the graph right after this, and a release segment
    /// nothing renders is a held voice by another name.
    ///
    /// Unlike `stop()` this moves neither transport, so `play()` resumes from where the pause left off. What it
    /// costs is a note held across the pause — the sequencer does not re-articulate it on resume, so the rest of
    /// that note is lost. Pause means silence here, as it does in MuseScore and in a DAW.
    public func pause() {
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.alignment.silenceRecordings()
            shared.synthesizer?.noteOffAll(immediate: true)
            shared.metronomeSynthesizer?.noteOffAll(immediate: true)
        }
    }

    public func stop() {
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.preRollFramesRemaining = 0
            shared.alignment.sequencerRepositioned()
            shared.alignment.silenceRecordings()
            shared.sequencer?.seek(to: .zero)
            shared.synthesizer?.noteOffAll(immediate: true)
            // Score tick 0 sits `metronomeOffsetSeconds` into a count-in
            // metronome sequence — rewinding it to zero would replay the count.
            shared.metronomeSequencer?.seek(to: Self.metronomePosition(0, in: shared))
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
        //
        // `tick` is a NOTATED score tick and the loaded SMF is the UNROLLED render, so the
        // notated seconds have to be projected onto the transport's own clock before they mean
        // anything to it. Identity on a score without repeats; on one with them this is the
        // difference between landing on the requested measure and landing on whatever the
        // sequence happens to be playing that many seconds in. The onset is projected first and
        // the half tick comes off on the unrolled clock (`UnrolledTimeMap.park`): projecting the
        // half-tick-earlier instant put the downbeat after a repeat at the end of the repeated
        // pass, so play-from there replayed the repeat.
        let park = unrolledTimeMap.park(atTick: tick, timeline: timeline)
        let seconds = park.parked
        lastPark = (parked: max(0, seconds), onset: park.onset)
        lock.withLockUnchecked { shared in
            // A seek is "play from here, now": it ends any count-in still owed
            // rather than counting the user in a second time from a new spot.
            shared.preRollFramesRemaining = 0
            // The recordings keep their playheads: a seek while playing (a loop wrap) is a jump of their read
            // position, which the playhead crossfades from where it was.
            shared.alignment.sequencerRepositioned()
            shared.sequencer?.seek(to: .seconds(seconds))
            shared.metronomeSequencer?.seek(to: Self.metronomePosition(seconds, in: shared))
        }
        // `MidiFileSequencer.seek` resets the synthesizer before chasing — same as `sequencer.play`
        // in `loadSequence` — so the persisted tuning is gone and only the SMF's own chased events
        // survive. `setTuning` is contracted to persist across transport operations (the RPN pair
        // has nothing in the SMF to restore it), so re-assert it here; otherwise a lock-screen skip
        // or a loop wrap silently drops the user's A4 calibration and transpose back to concert
        // pitch. Rate is re-sent alongside for symmetry — the sequencer keeps its `speed`, so that
        // half is a no-op.
        applyRateAndTuning()
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
        // The transport's clock is the UNROLLED sequence's; `timeline` is notated. Project before
        // the lookup, or a repeat's later passes report ticks from the wrong measure-play.
        return timeline.frame(
            atTime: unrolledTimeMap.notatedSeconds(fromUnrolled: currentPositionSeconds),
        )?.tick ?? 0
    }

    /// Forwarded straight from the transport: `MidiFileSequencer.isAtEnd` is
    /// `msgIndex == messages.count`, i.e. every message of the loaded SMF —
    /// including the end-of-track event the renderer emits one tick past the
    /// final note-off — has been dispatched.
    ///
    /// `false` when no sequence is loaded rather than the sequencer's own `true`:
    /// "we can't tell" must not read as "the piece is over", or the engine would
    /// stop a playback that never started. Note `stop()` here seeks the sequencer
    /// to zero instead of releasing its `MidiFile`, so this flips back to `false`
    /// after an end-of-score stop and the next `play` is not misread as finished.
    public var isAtEnd: Bool {
        lock.withLockUnchecked { $0.sequencer?.isAtEnd ?? false }
    }

    public func setProgram(channel: UInt8, program: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.processMidiMessage(
                channel: Int(channel), command: 0xC0, data1: Int(program), data2: 0,
            )
        }
        prefetchInBackground([PlayedPreset(channel: Int(channel), bank: 0, program: Int(program))])
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

    /// Sets the channel's bend sensitivity to the renderer's (RPN 0:0) before the wheel: `value` is scaled to it
    /// (`MidiEvent.pitchBendValue(cents:)`), and a channel no playback has reached yet is still at the GM default of
    /// 2 semitones, which would bend it a sixth as far.
    public func sendPitchBend(channel: UInt8, value: UInt16) {
        lock.withLockUnchecked {
            guard let synthesizer = $0.synthesizer else { return }
            let channel = Int(channel)
            func cc(_ controller: Int, _ value: Int) {
                synthesizer.processMidiMessage(channel: channel, command: 0xB0, data1: controller, data2: value)
            }
            cc(101, 0); cc(100, 0)
            cc(6, MidiEvent.pitchBendSensitivity); cc(38, 0)
            cc(101, 127); cc(100, 127)
            synthesizer.processMidiMessage(
                channel: channel, command: 0xE0, data1: Int(value & 0x7F), data2: Int((value >> 7) & 0x7F),
            )
        }
    }

    /// A second, independent backend for an offline export render, built at the
    /// export's own `sampleRate` — SwiftySynth fixes its render rate when the
    /// `Synthesizer` is created, so this is the only place the export's rate can
    /// be honored. Everything else (SoundFont, sequence, mixer, tuning) is pushed
    /// onto it by `PlaybackEngine+ExportBackend` from the export snapshot.
    ///
    /// Cheap to make: `init` only builds the `AVAudioSourceNode`; the SoundFont
    /// isn't touched until `prepare`.
    public func makeOfflineInstance(sampleRate: Double) -> (any SynthBackend)? {
        SwiftySynthBackend(sampleRate: sampleRate, stretcherFactory: stretcherFactory)
    }

    public func teardown() {
        // Supersede + cancel any in-flight load so it can't install a synth
        // post-teardown, and mark not-ready WITHOUT notifying — the engine clears
        // its own `isPreparingSoundfont` in its `teardown`. Setting `isReady`
        // false here also stops `play()` from driving a dead (nil-synth) transport
        // after teardown; it defers instead until the next `prepare`.
        loadGeneration += 1
        loadTask?.cancel()
        isReady = false
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.preRollFramesRemaining = 0
            shared.metronomeOffsetSeconds = 0
            shared.alignment.sequencerRepositioned()
            shared.alignment.silenceRecordings()
            shared.sequencer?.stop()
            shared.metronomeSequencer?.stop()
            shared.sequencer = nil
            shared.synthesizer = nil
            shared.metronomeSequencer = nil
            shared.metronomeSynthesizer = nil
        }
        scoreSoundFont = nil
        sequencePresets = []
    }
}
