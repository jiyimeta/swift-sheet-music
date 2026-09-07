// swiftlint:disable file_length
@preconcurrency import AVFoundation
import CSequencerHostTime
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

/// Audio playback for `Score`s, backed by `AVAudioEngine` and two
/// `AVAudioUnitMIDIInstrument` (AUMIDISynth) units: one for all
/// pitched channels and one for GM channel 9 (percussion).
///
/// Every staff in `prepare(score:)` is addressed by its part's live,
/// deduped MIDI channel (`LiveChannelPlan.build(score:)`) — the mixer
/// itself is keyed one strip per (part × distinct instrument), not
/// per staff, so a part that changes instrument mid-score gets one
/// strip per instrument instead of the score's rendered per-instance
/// channel count. The full General MIDI SoundFont returned by
/// `SoundfontResolver`
/// is loaded once into each unit, and every (channel, program)
/// combination is pre-loaded into the AU's preset cache so runtime
/// program changes from the mixer hit the cache instead of triggering
/// an unreliable on-demand SF2 read.
///
/// AUMIDISynth (`kAudioUnitSubType_MIDISynth`) is used in preference
/// to `AVAudioUnitSampler` because it is multi-timbral — one node
/// drives all 16 channels with per-channel programs, replacing the
/// pre-swap "one sampler per staff" graph. It is NOT used for pitch
/// bend: `AVAudioUnitSampler` honors RPN 0,0 and bends ±12 fine; the
/// original portamento-truncated-to-±2 symptom was an RPN-delivery bug
/// (the RPN never reached the bending channel), fixed by sending RPN
/// 0,0 = 12 directly to every channel at setup, not by the swap.
/// See `MIDISynthBuilder` for the wrapper that builds and configures
/// the instrument.
///
/// Splitting the two units lets whole-score transpose be applied via
/// global AU coarse tuning on the melodic unit only — AUMIDISynth
/// tuning is global-per-AU, not per-channel, so a single shared unit
/// would also detune the drums.
@MainActor
@Observable
public final class PlaybackEngine { // swiftlint:disable:this type_body_length
    private var resolver: SoundfontResolver
    /// Resolves the metronome's click sound (host WAVs → SF2, host SF2,
    /// or the GM drum-kit fallback). See `MetronomeClickResolver`.
    private var clickResolver: MetronomeClickResolver
    /// The metronome click provider captured at `init`, kept so
    /// `reloadSoundfont` can rebuild `clickResolver` against the new
    /// SoundFont resolver without the host re-supplying it.
    private let metronomeClickProvider: MetronomeClickProvider?
    /// The score last passed to `prepare(score:)`, so `reloadSoundfont`
    /// can re-prepare in place. `nil` until the first `prepare`. `internal` so
    /// `PlaybackEngine+ConfigurationChange` can check it before rebuilding.
    var loadedScore: Score?
    /// `internal` so `PlaybackEngine+Master` can call
    /// `engine.attach` / `engine.connect` from a sibling file when
    /// building the master output stage.
    let engine = AVAudioEngine()
    /// Pitched-channel synth. Carries A4 calibration AND whole-score
    /// transpose via its global AudioUnit coarse/fine tuning params.
    var melodicSynth: AVAudioUnitMIDIInstrument?
    /// Drum-channel (GM 9) synth. Carries calibration only — never the
    /// transpose — so transposing pitched content leaves drums at
    /// concert pitch. Separate unit because AUMIDISynth tuning is
    /// global-per-AU, not per-channel.
    var percussionSynth: AVAudioUnitMIDIInstrument?

    /// The synth that owns a given flat staff index: percussion for
    /// drum staves, melodic otherwise. `internal` so +Mixer can call it.
    func synth(forStaff idx: Int) -> AVAudioUnitMIDIInstrument? {
        isDrumStaff(idx) ? percussionSynth : melodicSynth
    }

    /// Both live synth units in a single array, nil slots compacted out.
    /// Used wherever we need to iterate over whichever units are currently
    /// attached — teardown, preview cancellation, etc.
    private var attachedSynths: [AVAudioUnitMIDIInstrument] {
        [melodicSynth, percussionSynth].compactMap(\.self)
    }

    /// Renderer-assigned MIDI channel per flat staff index — that
    /// staff's part's ORDINAL-0 (tick-0) instrument channel. Used to
    /// address each staff's notes / cursor preview on the shared synth.
    private var staffMIDIChannels: [Int: UInt8] = [:]
    /// Drum-staff flag per flat staff index, cached so the mixer can
    /// decide whether to expose a GM-program picker (drum-kit parts
    /// hide it because the program slot is ignored on MIDI channel 9).
    private var staffIsDrum: [Int: Bool] = [:]
    /// The live single-port channel layout for the prepared score —
    /// one strip per (part × distinct instrument), collapsing the
    /// MuseScore-exact multi-port SMF onto the 16 channels a single
    /// synth has. Rebuilt in `prepareSynth(score:)`; `nil` before the
    /// first prepare.
    private(set) var liveChannelPlan: LiveChannelPlan?
    /// Live MIDI channel per mixer strip identity. Keyed the same way
    /// as `mixerChannels`, so every strip — not just each staff's
    /// tick-0 primary — can be addressed directly.
    private var instrumentMIDIChannels: [MixerChannel.Kind: UInt8] = [:]
    /// Per-flat-staff channel switches, ascending by tick. Precomputed
    /// in `prepareSynth(score:)` because the engine does not retain the
    /// prepared `Score`. Empty for a staff whose part never changes
    /// instrument.
    private var staffChannelSwitches: [Int: [(tick: Int, channel: UInt8)]] = [:]

    /// Master output stage. The score synth and the metronome both feed
    /// `scoreGainMixer`, whose `outputVolume` is the user's master gain
    /// (`0...`). Its output passes through `sumMixer`, then `softClip`
    /// and `limiter` — both bypassed unless
    /// `masterOutputStage` selects one — then routed into
    /// `mainMixerNode`. `sumMixer` no longer sums anything the gain
    /// stage didn't already; it stays as the metering tap point (see
    /// `+Metering`), which must read the post-gain mix. Built once in
    /// `init` and reused across every `prepare(score:)`, so `masterGain`
    /// survives score reloads. `internal` so the `+Master` / `+Export`
    /// extensions in sibling files can reach the nodes directly.
    let scoreGainMixer = AVAudioMixerNode()
    let sumMixer = AVAudioMixerNode()
    let softClip = SoftClipAudioUnit.makeNode()
    let limiter = PlaybackEngine.makePeakLimiter()

    /// Which shaping node — if any — is active past full scale. Setter is
    /// module-internal so the `+Master` extension (a different file) can
    /// mirror the value here. See `MasterOutputStage` for why `.none` is
    /// the default.
    public internal(set) var masterOutputStage: MasterOutputStage = .none // swiftlint:disable:this inclusive_language

    /// Linear amplitude multiplier applied to the full mix, post
    /// per-channel mixing. `1.0` = unity. Floored at `0` by
    /// `setMasterGain`; no ceiling. Setter is module-internal so the
    /// `+Master` extension (a different file) can mirror the value here.
    public internal(set) var masterGain: Float = 1.0 // swiftlint:disable:this inclusive_language

    /// `true` while a peak-level tap is installed on `sumMixer`. Setter is
    /// module-internal so the `+Metering` extension (a different file) can
    /// mirror the tap's lifecycle here.
    public internal(set) var isLevelMonitoring = false

    /// Current A4-calibration offset in cents (0 = A4 440 Hz). Stored so it survives
    /// synth rebuilds in `prepareSynth`, like `masterGain`.
    public private(set) var masterTuningCents: Double = 0 // swiftlint:disable:this inclusive_language

    /// Whole-score transpose in semitones (`-12…+12`). Applied as MIDI
    /// coarse tuning to every pitched channel; re-applied after each
    /// `prepare(score:)` so a score reload preserves it. `0` = concert.
    public private(set) var transposeSemitones = 0

    /// Used to silence pending preview note-offs when the engine is
    /// torn down or a new score is prepared.
    private let previewQueue = DispatchQueue(
        label: "swift-sheet-music.playback.preview",
        qos: .userInteractive,
    )
    /// The single tap-preview note currently sounding (`(channel, pitch)`), or
    /// `nil`. A new preview clears it first: on a *different* channel with All
    /// Sound Off (CC 120, which also truncates a ringing drum cymbal a note-off
    /// would leave decaying); on the *same* channel with a plain note-off —
    /// because CC 120 immediately followed by a note-on on the same channel
    /// gets swallowed by AUMIDISynth (the next drum tap would be silent), and a
    /// drum re-hit overlapping its own decay is natural anyway. Main-actor
    /// isolated.
    /// Which fixed-duration tap preview is sounding, which of them supersedes which, and how long each one
    /// rings and then occupies the graph.
    ///
    /// Shared with the Android engine, which runs the same `NotePreviewPolicy` over JNI. It used to be a pair of
    /// fields here and a hand-written copy of them there; the copy reproduced neither the supersede nor the
    /// release tail, and both omissions were audible. The MIDI each engine sends stays its own — this decides
    /// *what* happens, not how it is said.
    ///
    /// A generation rather than a `DispatchWorkItem`: a `DispatchWorkItem`'s Swift block inherits this
    /// `@MainActor` class's isolation and trips the actor-executor assertion (EXC_BREAKPOINT) when run on
    /// `previewQueue`; the `@convention(block)` trailing closure of `asyncAfter(deadline:)` does not.
    private var previewPolicy = NotePreviewPolicy()
    /// The held sustained preview (bar press-hold), distinct from the policy's tap preview. Main-actor isolated.
    ///
    /// Deliberately not in the shared policy: a sustained hold has no duration to plan, it ends when the finger
    /// lifts, and Android has no bar press-hold to mirror. The two do interact — see `previewNoteOff`.
    private var activeSustainedPreview: (staff: Int, channel: UInt8, pitch: UInt8)?
    /// True when a preview resumed an audio graph the host had paused.
    /// Tells the drain to restore that paused state once previews drain
    /// — preserving the host's "graph parked until play" behavior.
    private var previewShouldRepauseEngineOnDrain = false

    /// Sequencer used for full-score playback. Lazily built the
    /// first time `play(...)` is called for a given score.
    private var sequencer: AVAudioSequencer?
    /// Score the sequencer was built from. When `prepare` runs
    /// against a different score, the sequencer is torn down so
    /// the next `play` rebuilds it.
    private var sequencerScore: Score?
    /// True when the metronome sequence currently loaded on the backend is a
    /// count-in build (pre-roll clicks in front of the shifted body). The score
    /// transport's own SMF is never shifted on this path, so only the metronome
    /// side has to be swapped back before an ordinary play. Unused on the
    /// AUMIDISynth path, which drives its pre-roll through `SequenceMap`.
    private var backendMetronomeHasPreRoll = false
    /// Translates the sequencer's raw tick space to the score's. A
    /// count-in play shifts all score content forward past a pre-roll
    /// region (`SequenceMap(preRollTicks:baseTick:)`); a normal play
    /// leaves it `.identity` (pass-through). EVERY raw read/write of
    /// `sequencer.currentPositionInBeats` is routed through this so the
    /// cursor, loop-wrap, seek, skip, and time reporting all speak
    /// score ticks regardless of the pre-roll offset.
    private var sequenceMap: SequenceMap = .identity
    /// True when the loaded sequence is a count-in build (shifted +
    /// pre-roll click track). A normal `play` reuses an existing
    /// sequencer for the same score, but a count-in sequence is
    /// start-cursor-specific (the shift depends on `baseTick`), so it
    /// must be rebuilt every count-in play and must NOT be silently
    /// reused as a normal sequence — this flag forces a normal rebuild
    /// after any count-in.
    private var sequencerHasPreRoll = false
    /// Cached `MidiRenderer.render(score:)` output (the expensive step),
    /// keyed by the score it was rendered from. A count-in play
    /// re-assembles the SMF (shift + pre-roll) on every start; caching
    /// the render keeps per-play cost at re-assembly + `sequencer.load`
    /// rather than a full re-render of every note.
    private var renderedMidiCache: (score: Score, midi: MidiFile)?
    /// Most recent rate set by the host. Stored separately from the
    /// sequencer so the value survives `buildSequencer` rebuilds —
    /// every fresh `AVAudioSequencer` starts at 1.0 and we re-apply
    /// this value once it's built.
    private var pendingRate: Float = 1.0
    /// Pre-computed time → item mapping, used by the cursor poll
    /// to translate `sequencer.currentPositionInSeconds` into a
    /// `ScoreItemID`.
    private var timeline: PlaybackTimeline?
    /// Unrolled→notated tick map for the loaded score. The sequencer
    /// plays `MidiRenderer.render`'s UNROLLED SMF (repeats + jumps
    /// expanded) while `timeline` frames are in NOTATED ticks; every
    /// cursor / time READ translates through this map. Scheduling —
    /// loop wrap, seek, play-from — intentionally stays in
    /// first-occurrence coordinates (tap-to-seek targets a notated
    /// tick's first unrolled occurrence).
    private var unroll: PlaybackUnroll = .identity
    /// Unrolled-transport seconds → notated-timeline seconds, rebuilt with `unroll` in
    /// `prepare`. Only the injected-backend path needs it: that backend's clock is seconds on
    /// the unrolled SMF, whereas the AUMIDISynth path polls unrolled TICKS and can use
    /// `unroll.notatedTick(fromUnrolled:)` directly.
    private var unrolledTimeMap: UnrolledTimeMap = .identity
    /// Cursor poll timer — fires at ~30 Hz while playing, updates
    /// `currentItem`.
    private var cursorTimer: Timer?

    /// Metronome — owns its own sampler (GM percussion) and a
    /// dedicated sequencer track. Mirrors MuseScore's "always on,
    /// host can mute" model. See `MetronomeController` for details.
    private let metronome: MetronomeController
    /// Beats for the current score, cached on `prepare(score:)` and
    /// re-handed to the metronome whenever the sequencer is rebuilt.
    private var metronomeBeats: [MetronomeBeat] = []

    public private(set) var state: PlaybackState = .stopped
    public private(set) var currentCursor: ScoreCursor?
    /// When non-nil, `tickCursor` snaps the sequencer back to
    /// `startTick` whenever the polled raw position reaches `endTick`,
    /// re-seating *all* tracks — including the SMF's master tempo
    /// track. `AVMusicTrack.loopRange` would wrap the per-staff music
    /// tracks sample-accurately but leaves the tempo track playing
    /// through monotonically, so mid-loop `.tempo` / `.timeSignature`
    /// meta events would fire on iteration 1 only and iteration 2+
    /// would stay frozen at whichever tempo was last set before the
    /// wrap. Manual seek mirrors the host-driven `seek(to:)` path
    /// (writing `currentPositionInBeats` reruns AVAudioSequencer's
    /// tempo-track event scan), which is the same reason a user's
    /// tap-to-seek "fixes" stuck tempo on a hung loop. Trade-off: the
    /// wrap loses sample-accurate continuity (cursor timer drives
    /// detection at ~30 Hz), so a chord ringing into the wrap point
    /// gets cut off. `play(...)` and `seek(...)` still snap into the
    /// region when called outside it.
    public private(set) var loopRange: LoopRange?
    /// One strip per staff plus a metronome strip. Rebuilt on each
    /// `prepare(score:)` call; mutated through `setVolume / setMuted
    /// / setSoloed`. Hosts bind a SwiftUI mixer view directly to
    /// this array and re-render on change.
    public private(set) var mixerChannels: [MixerChannel] = []

    /// When set, an alternate synth + transport backend (e.g. SwiftySynth)
    /// replaces the built-in AUMIDISynth path. Injected by a host that wants to
    /// avoid AUMIDISynth's voice stealing; `nil` keeps the default AUMIDISynth.
    /// `internal` so the `+Mixer` extension can branch on it.
    let backend: (any SynthBackend)?

    /// `true` when playback is delegated to an injected `SynthBackend`.
    var usingBackend: Bool {
        backend != nil
    }

    /// `true` while the injected backend loads its SoundFont asynchronously (see
    /// `SynthBackend.isReady`). A host observes this to show a "preparing" state;
    /// a play requested during this window is deferred (`pendingBackendPlay`) and
    /// starts automatically once loading finishes. Always `false` on the
    /// AUMIDISynth path, which loads synchronously.
    public private(set) var isPreparingSoundfont = false

    /// The error from the most recent **automatic** graph rebuild that failed, or `nil` if the last one succeeded.
    ///
    /// Two things rebuild the graph without the host asking directly: a SoundFont hot-swap
    /// (`reloadSoundfont(resolver:)`) and an audio I/O configuration change (an output-device switch on macOS, a
    /// route change on iOS — see `PlaybackEngine+ConfigurationChange`). Both re-run `prepare(score:)`, which can
    /// throw from `engine.start()`. Before this existed the failure was swallowed: the engine went quiet, the mixer
    /// was back at score defaults, and nothing said so. A host can surface this, or re-`prepare` on it.
    ///
    /// Cleared by the next rebuild that completes. Never set by an explicit `prepare(score:)` — that one throws to
    /// its caller, who is in a position to handle it.
    public private(set) var lastGraphRestartError: (any Error)?

    /// Completed `restartGraphPreservingState()` calls. Not host-facing state: it exists so a test can tell
    /// "the restart ran" from "nothing happened", which no other observable distinguishes when a rebuild is
    /// successful and therefore invisible.
    private(set) var graphRestartCount = 0

    /// Test-only injection: the next `restartGraphPreservingState()` throws this instead of rebuilding, and clears
    /// it. It throws *before* `prepare(score:)` runs — which is deliberately unlike the real failure (inside
    /// `prepare`, after it has already stopped the transport), because that is what leaves `state` still claiming
    /// `.playing` and so actually exercises the caller's obligation to correct it.
    var graphRestartFailureForTesting: (any Error)?

    /// A play requested while the backend was still loading its SoundFont,
    /// replayed the moment the backend reports ready.
    private var pendingBackendPlay: (cursor: ScoreCursor?, score: Score, countIn: Bool)?

    /// How this engine treats the process-wide `AVAudioSession`. See `AudioSessionPolicy`. `internal` so the
    /// `+AudioSession` extension can branch on it.
    let audioSessionPolicy: AudioSessionPolicy

    /// `true` once a `.mixUntilPlay` engine has taken the session exclusively for a `play(...)`. Keeps a re-prepare
    /// (SoundFont hot-swap) from demoting the session back to mixing, and keeps the escalation to one write per engine
    /// lifetime. Cleared by `teardown()` and by an interruption. `internal` for the `+AudioSession` extension.
    var hasEscalatedAudioSession = false

    /// `true` between an interruption deactivating the session and the next thing that needs to sound. A session
    /// survives an interruption with its *category* intact, so re-activating it — which `AVAudioEngine.start()` does
    /// implicitly — would silence the interrupter all over again if that category were the exclusive one a
    /// `play(...)` escalated to. See `prepareAudioSessionForPreview()`. `internal` for the `+AudioSession` extension.
    var needsAudioSessionReactivation = false

    /// Holder for the block-based `AVAudioSession.interruptionNotification` observer token. `internal` for the
    /// `+AudioSession` extension that fills it in; see `startObservingAudioSessionInterruptions()`.
    let interruptionObserver = NotificationObserverToken()

    /// Holder for the block-based `AVAudioEngineConfigurationChange` observer token. `internal` for the
    /// `+ConfigurationChange` extension that fills it in; see `startObservingConfigurationChanges()`.
    let configurationChangeObserver = NotificationObserverToken()

    /// The scheduled, not-yet-run rebuild for an audio configuration change, or `nil` when none is pending.
    /// Holding it is what collapses a burst of notifications into one rebuild. `internal` for the
    /// `+ConfigurationChange` extension.
    var pendingConfigurationRestart: Task<Void, Never>?

    /// `true` for the duration of `performConfigurationChangeRestart()` (set at its start, cleared by its `defer`).
    /// Consulted at the top of `configurationChangeDidPost()`, which returns early while it is set.
    ///
    /// `NotificationCenter` delivers a `queue: .main` block SYNCHRONOUSLY when the post happens on the main
    /// thread, so our own `prepare(score:)` — called from inside `restartGraphPreservingState()` — can post
    /// `AVAudioEngineConfigurationChange` reentrantly while this rebuild is still on the stack; that reentrant post
    /// is exactly what this flag drops. A genuine EXTERNAL device change arriving while the main actor is busy
    /// inside the rebuild is *enqueued* by `NotificationCenter` instead of delivered synchronously, so it is not
    /// seen until `configurationChangeDidPost()` runs again after the rebuild returns and this flag has already
    /// been cleared — it survives the flag, it just waits its turn. `internal` for the `+ConfigurationChange`
    /// extension.
    var isRebuildingForConfigurationChange = false

    public init(
        soundfontResolver: SoundfontResolver,
        metronomeClickProvider metronomeClickProvider0: MetronomeClickProvider? = nil,
        backend: (any SynthBackend)? = nil,
        audioSessionPolicy: AudioSessionPolicy = .exclusiveOnPrepare,
    ) {
        resolver = soundfontResolver
        self.backend = backend
        self.audioSessionPolicy = audioSessionPolicy
        metronomeClickProvider = metronomeClickProvider0
        clickResolver = MetronomeClickResolver(
            provider: metronomeClickProvider0,
            soundfontResolver: soundfontResolver,
        )
        // The metronome joins the master stage at `scoreGainMixer`, i.e. the
        // click IS scaled by the master gain, along with the score.
        //
        // It used to land on `sumMixer` (post-gain) so the click stayed a fixed
        // reference while the score was boosted. That was only ever true on the
        // AUMIDISynth path: an injected `SynthBackend` mixes its own click
        // inside its render block and hands back ONE node, which connects here
        // to `scoreGainMixer` — so on the backend path the click has always
        // tracked the gain. Rather than give backends a second output node to
        // keep a split nobody asked for, the two paths are unified on the
        // backend's behavior, which is also the more useful one: `masterGain`
        // is documented as calibration for a quiet backend
        // (see `setMasterGain`), and a click that ignored it would silently
        // rebalance score-against-click every time the user calibrated.
        metronome = MetronomeController(engine: engine, output: scoreGainMixer)
        buildMasterChain()
        startObservingAudioSessionInterruptions()
        startObservingConfigurationChanges()
    }

    /// Scale playback speed. `1.0` is the score's native tempo;
    /// `0.5`–`2.0` is the host's typical slider range, but no
    /// clamping is applied here — the caller is expected to enforce
    /// musically reasonable bounds. The new value persists across
    /// sequencer rebuilds (e.g. `play(from:in:)` on a fresh score).
    public func setRate(_ rate: Float) {
        guard state != .exporting else { return }
        pendingRate = rate
        sequencer?.rate = rate
        backend?.setRate(rate)
    }

    /// Retune playback to an A4 reference expressed as a cents offset from 440 Hz
    /// (e.g. 432 Hz ≈ -31.77¢). AUMIDISynth ignores MIDI master-tuning RPNs but
    /// honors its global AudioUnit Coarse/Fine Tuning params, which we set here —
    /// covering every channel with zero latency. Persists across `prepare`.
    public func setMasterTuning(cents: Double) { // swiftlint:disable:this inclusive_language
        guard state != .exporting else { return }
        masterTuningCents = cents
        applyTuning()
    }

    /// AUMIDISynth global-scope AudioUnit tuning parameter ids (from its
    /// `kAudioUnitProperty_ParameterList`): 901 = Coarse Tuning (semitones),
    /// 902 = Fine Tuning (cents).
    private static let coarseTuningParameterID: AudioUnitParameterID = 901
    private static let fineTuningParameterID: AudioUnitParameterID = 902

    /// `internal` (not `private`) so `PlaybackEngine+Export` (a
    /// different file) can reproduce the live engine's transpose +
    /// master A4 tuning on the offline export synths.
    static func applyMasterTuning( // swiftlint:disable:this inclusive_language
        to instrument: AVAudioUnitMIDIInstrument, cents: Double,
    ) {
        let split = MasterTuning.split(cents: cents)
        AudioUnitSetParameter(
            instrument.audioUnit, coarseTuningParameterID, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(split.coarseSemitones), 0,
        )
        AudioUnitSetParameter(
            instrument.audioUnit, fineTuningParameterID, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(split.fineCents), 0,
        )
    }

    // MARK: Internal accessors for `PlaybackEngine+Export`

    func setStateForExport(_ newState: PlaybackState) {
        state = newState
    }

    func exportTimeline() -> PlaybackTimeline? {
        timeline
    }

    /// Snapshot of mutable engine state captured at export start, so
    /// the export pipeline can reproduce live mixer / metronome /
    /// rate behavior on its own dedicated `AVAudioEngine` without
    /// reaching back into the live engine while rendering.
    struct ExportEngineSnapshot {
        let resolver: SoundfontResolver
        let mixerChannels: [MixerChannel]
        let metronomeEnabled: Bool
        let metronomeVolume: Float
        let rate: Float
        let metronomeBeats: [MetronomeBeat]
        /// Linear amplitude multiplier captured from
        /// `PlaybackEngine.masterGain`, so the export engine rebuilds
        /// the master stage at the same gain the user hears live.
        let masterGain: Float // swiftlint:disable:this inclusive_language
        /// Shaping stage captured from `PlaybackEngine.masterOutputStage`,
        /// so an export that was driven past full scale is shaped the same
        /// way the user just heard it.
        let masterOutputStage: MasterOutputStage // swiftlint:disable:this inclusive_language
        /// Resolved metronome SoundFont URL (host click SF2, host SF2, or
        /// GM drum-kit), so the export plays the same click as live.
        let metronomeSoundFontURL: URL?
        /// Whole-score transpose captured from `PlaybackEngine.transposeSemitones`,
        /// so the export synths reproduce the live engine's key shift.
        let transposeSemitones: Int
        /// A4-calibration offset captured from `PlaybackEngine.masterTuningCents`,
        /// so the export synths reproduce the live engine's tuning.
        let masterTuningCents: Double // swiftlint:disable:this inclusive_language
    }

    func exportEngineSnapshot() -> ExportEngineSnapshot {
        ExportEngineSnapshot(
            resolver: resolver,
            mixerChannels: mixerChannels,
            metronomeEnabled: metronome.isEnabled,
            metronomeVolume: metronome.volume,
            rate: pendingRate,
            metronomeBeats: metronomeBeats,
            masterGain: masterGain,
            masterOutputStage: masterOutputStage,
            metronomeSoundFontURL: clickResolver.resolvedSoundFontURL(),
            transposeSemitones: transposeSemitones,
            masterTuningCents: masterTuningCents,
        )
    }

    /// Test-only read-back of the node the live metronome's synth actually
    /// feeds, so a test can assert the click joins the master chain AT the
    /// gain stage (`scoreGainMixer`) rather than after it. Read from the
    /// engine's own connection table, not from what `MetronomeController` was
    /// handed, so a rewiring that never reached the graph would still fail.
    /// `nil` until `prepare(score:)` has built the synth.
    var metronomeOutputDestination: AVAudioNode? {
        guard let sampler = metronome.attachedSampler else { return nil }
        return engine.outputConnectionPoints(for: sampler, outputBus: 0)
            .first?.node
    }

    // MARK: Internal accessors for `PlaybackEngine+Mixer`

    func midiChannel(forStaff idx: Int) -> UInt8? {
        staffMIDIChannels[idx]
    }

    /// The live MIDI channel `flatStaffIndex` sounds on at `tick`.
    ///
    /// A tap preview at the cursor must audition the instrument active
    /// THERE, not the part's opening instrument — otherwise tapping a
    /// note after an instrument change sounds the wrong timbre.
    /// Falls back to the staff's tick-0 channel when the part has no
    /// instrument changes.
    public func midiChannel(
        forStaff flatStaffIndex: Int, atTick tick: Int,
    ) -> UInt8? {
        guard let switches = staffChannelSwitches[flatStaffIndex],
              !switches.isEmpty
        else { return midiChannel(forStaff: flatStaffIndex) }
        var result = midiChannel(forStaff: flatStaffIndex)
        for entry in switches {
            if entry.tick <= tick { result = entry.channel } else { break }
        }
        return result
    }

    /// Live MIDI channel for a mixer strip identity. `nil` before the
    /// first `prepare(score:)`, or for a `Kind` not in the prepared
    /// score's plan.
    func midiChannel(forChannel id: MixerChannel.Kind) -> UInt8? {
        instrumentMIDIChannels[id]
    }

    func isDrumStaff(_ idx: Int) -> Bool {
        staffIsDrum[idx] ?? false
    }

    /// Live whole-score transpose in semitones (clamped −12…+12). Global
    /// coarse tuning on the MELODIC unit only, so pitched content (incl.
    /// already-sounding notes) shifts zero-artifact and drums stay put.
    ///
    /// An octave either way, not the old diminished fifth: a singer moving a
    /// song out of its written key routinely needs one, and the MIDI coarse
    /// tuning RPN carries ±64 semitones so the old limit bought nothing. The
    /// NOTATION half (`LayoutOptionsWire.transposeDelta`) is clamped to the
    /// same range and must move with it — a wider sound than notation makes
    /// the score look and sound like different pieces past the narrower bound.
    public func setTranspose(semitones: Int) {
        let clamped = max(-12, min(12, semitones))
        transposeSemitones = clamped
        applyTuning()
    }

    /// Push calibration + transpose onto both units' global AU tuning.
    /// Melodic = calibration + transpose; percussion = calibration only.
    private func applyTuning() {
        if let backend {
            backend.setTuning(
                cents: masterTuningCents, transposeSemitones: transposeSemitones,
            )
            return
        }
        if let melodicSynth {
            Self.applyMasterTuning(
                to: melodicSynth,
                cents: masterTuningCents + Double(transposeSemitones) * 100,
            )
        }
        if let percussionSynth {
            Self.applyMasterTuning(to: percussionSynth, cents: masterTuningCents)
        }
    }

    /// Re-send program-change on each staff's primary channel using
    /// the program the mixer currently advertises. Called right after
    /// `sequencer.start()` so the SMF's tick-0 programChange events
    /// have already fired and our re-apply wins the race; also called
    /// after the user changes a program from the picker while the
    /// engine was paused, since the queued event from that picker
    /// click can lose to the SMF on resume.
    func reapplyMixerPrograms() {
        if let backend {
            for channel in mixerChannels {
                guard case .instrument = channel.id,
                      let program = channel.program,
                      let midiCh = instrumentMIDIChannels[channel.id],
                      midiCh != 9
                else { continue }
                backend.setProgram(channel: midiCh, program: program)
            }
            return
        }
        guard let melodicSynth else { return }
        for channel in mixerChannels {
            guard case .instrument = channel.id,
                  let program = channel.program,
                  let midiCh = instrumentMIDIChannels[channel.id],
                  midiCh != 9
            else { continue }
            // Same dance as `loadProgram`: preload to populate the
            // channel's preset slot, then plain PC to select it.
            MIDISynthBuilder.preloadPreset(
                into: melodicSynth,
                bankMSB: 0, bankLSB: 0, program: program,
                onChannel: midiCh,
            )
            let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
            _ = MusicDeviceMIDIEvent(
                melodicSynth.audioUnit, pcStatus, UInt32(program), 0, 0,
            )
        }
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        metronome.isEnabled = enabled
        // The injected backend plays the metronome on a separate synth that is
        // always in lockstep with the score, so enabling / disabling it is a
        // live mute — no SMF reload, so a mid-playback toggle never resets the
        // score synth (which would cut every sounding voice).
        backend?.setMetronomeMuted(!enabled)
    }

    func setMetronomeVolume(_ volume: Float) {
        metronome.volume = volume
        // The injected backend mixes its own click, so the strip's volume has to
        // reach it too — the AUMIDISynth metronome above is silent on that path.
        backend?.setMetronomeVolume(volume)
    }

    func replaceMixerChannels(_ channels: [MixerChannel]) {
        mixerChannels = channels
    }

    func mutateMixerChannel(
        at idx: Int, _ change: (inout MixerChannel) -> Void,
    ) {
        change(&mixerChannels[idx])
    }

    /// Swap the GM program on `idx`'s output. AUMIDISynth's preset
    /// cache holds only one slot per channel, so a plain runtime
    /// program-change to a patch the channel has never seen forces an
    /// unreliable on-demand SF2 read — some patches end up silent.
    /// And a `preloadPreset` (EnablePreload ON → CC/PC → OFF) alone
    /// loads the preset into the slot but doesn't actually *select* it
    /// as the channel's current program. We need both steps:
    ///   1. `preloadPreset` to populate the channel's preset slot
    ///   2. a plain `MusicDeviceMIDIEvent` programChange (outside the
    ///      preload window) to select the now-cached preset
    /// No-op if the engine isn't prepared, or for drum staves (the
    /// program byte is ignored on MIDI channel 9).
    func loadProgram(forStaff idx: Int, program: UInt8) {
        guard let midiCh = staffMIDIChannels[idx] else { return }
        loadProgram(onMIDIChannel: midiCh, program: program)
    }

    /// Sibling of `loadProgram(forStaff:)`, keyed by mixer strip
    /// identity instead of staff — the mixer addresses a (part ×
    /// instrument) strip, which for a multi-instrument part is not the
    /// same thing as any one staff.
    func loadProgram(forChannel id: MixerChannel.Kind, program: UInt8) {
        guard let midiCh = instrumentMIDIChannels[id] else { return }
        loadProgram(onMIDIChannel: midiCh, program: program)
    }

    /// A program change on the GM drum channel selects the KIT, so it is
    /// routed to the percussion unit's bank 128 rather than to a melodic
    /// preset in bank 0. Both this and its callers used to refuse
    /// channel 9 outright, which had two consequences: a host's drum-kit
    /// picker changed nothing, and the score's OWN authored kit never
    /// arrived either — `postProcessForMIDISynth` strips the SMF's
    /// tick-0 program for every mixer-managed channel, and the drum
    /// channel is one, so nothing was left to send it.
    private func loadProgram(onMIDIChannel midiCh: UInt8, program: UInt8) {
        if let backend {
            backend.setProgram(channel: midiCh, program: program)
            return
        }
        // 9 is the GM drum channel. Named locally rather than reaching for
        // `MidiRenderer.drumChannel`, which is internal to SheetMusicMIDI.
        let isDrum = midiCh == 9
        guard let unit = isDrum ? percussionSynth : melodicSynth else { return }
        MIDISynthBuilder.preloadPreset(
            into: unit,
            bankMSB: isDrum ? 128 : 0, bankLSB: 0, program: program,
            onChannel: midiCh,
        )
        let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
        _ = MusicDeviceMIDIEvent(
            unit.audioUnit, pcStatus, UInt32(program), 0, 0,
        )
    }

    /// Build per-staff samplers, load their SoundFont presets, and
    /// start the audio engine. Idempotent: calling again with a
    /// different score replaces the samplers.
    ///
    /// Synchronous and potentially slow on first call:
    /// `kMusicDeviceProperty_SoundBankURL` + the preload program-change
    /// dance blocks while the SF2 file is parsed (tens of ms per file
    /// is typical, more on iPhone for the full GM SF2). Wrap the call
    /// in `Task.detached(priority: .userInitiated) { … }` if you want
    /// the UI to stay responsive during score load.
    public func prepare(score: Score) throws { // swiftlint:disable:this function_body_length
        // If an export is in flight the caller is expected to cancel its
        // `Task` before calling `prepare(score:)` on a different score.
        // We don't cancel for them — but we do refuse to tear down the
        // samplers under the exporter's feet.
        if state == .exporting {
            return
        }
        loadedScore = score
        // A host that reads `lastGraphRestartError` and re-`prepare`s on it (the recovery path its own doc
        // describes) needs this to actually dismiss — it was never cleared here before, so `@Observable` state
        // from a failed automatic rebuild stuck around even after a successful manual `prepare`.
        lastGraphRestartError = nil
        // Stop any in-flight playback before tearing down samplers.
        stop()
        // Drop any ringing tap-preview so it can't outlive this synth.
        cancelActivePreview()
        // Loop ticks are resolved against the previous timeline; clear
        // them so a stale region from the prior score can't fire on
        // the new one.
        clearLoop()
        // Quiesce the render IO thread before mutating the audio graph below.
        // Freeing the sequencer, reloading the metronome's soundbank, and
        // detaching the previous score's synths all edit graph state the render
        // thread may still be touching. `stop()` above only *pauses* the engine,
        // so without a hard stop the detach races the in-flight render cycle and
        // frees sampler voice memory out from under it — faulting on the IO
        // thread as `ProcessMono` / `SamplerNote::Render` in Crashlytics, the
        // same race `teardown()` guards against. `engine.start()` below spins it
        // back up; `stop()` is a no-op on an already-stopped engine.
        engine.stop()
        sequencer = nil
        sequencerScore = nil
        sequenceMap = .identity
        sequencerHasPreRoll = false
        backendMetronomeHasPreRoll = false
        renderedMidiCache = nil
        let preparedTimeline = PlaybackTimeline(score: score)
        timeline = preparedTimeline
        unroll = MidiRenderer.playbackUnroll(score: score)
        unrolledTimeMap = UnrolledTimeMap(unroll: unroll, timeline: preparedTimeline)
        // UNROLLED (not notated) — playback drives the sequencer's
        // rendered SMF, which has repeats + jumps expanded. A body
        // metronome track built from notated ticks alone would end at
        // the notated length and go silent on a repeat's 2nd pass (or
        // any jump), even though the score keeps playing. The count-in
        // pre-roll click track (`CountInBeats.Result.beats`, assembled
        // separately in `buildCountInSequencer`) is unaffected — it
        // always plays from a fixed start, once.
        metronomeBeats = PlaybackTimeline.unrolledMetronomeBeats(score: score)
        // Resolve the metronome's SoundFont through the click provider:
        // `.clickSamples` builds an SF2 from the host's WAVs, `.soundFont`
        // uses a host SF2, and `.defaultGM` (or no provider) falls back to
        // the GM drum-kit (notes 76 / 77). AUMIDISynth loads it unchanged.
        metronome.prepare(soundfontURL: clickResolver.resolvedSoundFontURL())
        // Tear down the synths from a previous score, if any.
        for old in attachedSynths {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        melodicSynth = nil
        percussionSynth = nil
        staffMIDIChannels.removeAll()
        staffIsDrum.removeAll()
        liveChannelPlan = nil
        instrumentMIDIChannels.removeAll()
        staffChannelSwitches.removeAll()

        // Category / activation per `audioSessionPolicy` — see `PlaybackEngine+AudioSession`. Deliberately BEFORE
        // `prepareSynth`: the synths are built against whatever route the session ends up on.
        configureAudioSessionForPrepare()

        try prepareSynth(score: score)

        rebuildMixerChannels(for: score)
        applyMixerState()

        if !engine.isRunning {
            try engine.start()
        }
        // Select each non-drum channel's program now — *after* the graph is
        // running, so the program-change MIDI events actually reach the synth.
        // Selection otherwise only happens in `reapplyMixerPrograms()` right
        // after `sequencer.start()` (the first `play()`), so a tap-preview
        // fired before any playback would sound on the SF2 seed preset
        // (GM program 0 = piano). Real playback re-applies programs after
        // `sequencer.start()` to win the race against the SMF's tick-0
        // program-change events, so playback behavior is unchanged.
        reapplyMixerPrograms()
    }

    /// Swap the SoundFont resolver and reload every sampler for the
    /// currently-loaded score in place, preserving playback position,
    /// mixer state (volume / mute / solo / program), rate, and tuning.
    ///
    /// If no score has been prepared yet, this only replaces the
    /// resolver; the new one takes effect on the next `prepare(score:)`.
    ///
    /// No-op while exporting.
    ///
    /// Best-effort on failure, with two blind spots the host currently
    /// cannot observe (a future `prepareWithDiagnostics`-style API should
    /// surface both, mirroring `MSCXParser.parseWithDiagnostics`):
    /// - If the re-prepare throws (only `engine.start()` can), the swap is
    ///   abandoned and the engine is left stopped with the mixer reset to the
    ///   score's defaults. The error itself is no longer lost — it lands in
    ///   `lastGraphRestartError` — but nothing is thrown from here.
    /// - A missing / corrupt SoundFont does NOT fail here: the AU rejects
    ///   the file inside `prepareSynth`'s `try?`-guarded `loadSoundFont`,
    ///   so the sampler stays attached but silent and this returns as if
    ///   the swap succeeded. This is the failure a SoundFont picker most
    ///   wants to report, yet nothing is thrown or flagged.
    public func reloadSoundfont(resolver newResolver: SoundfontResolver) {
        guard state != .exporting else { return }
        resolver = newResolver
        // Rebuild the metronome click resolver so its GM drum-kit fallback
        // — and therefore the metronome sampler after the re-prepare below —
        // follows the new SoundFont. A bare re-prepare without this leaves
        // the metronome bound to the old font (observed in Folino).
        clickResolver = MetronomeClickResolver(
            provider: metronomeClickProvider, soundfontResolver: newResolver,
        )
        do {
            try restartGraphPreservingState()
        } catch {
            recordGraphRestartFailure(error)
        }
    }

    /// Re-`prepare` the currently-loaded score in place, preserving what `prepare(score:)` would otherwise reset:
    /// the cursor, the playing / paused transport, and the per-channel mixer state (volume / mute / solo / program).
    /// `rate`, `masterTuningCents` and `transposeSemitones` are engine fields re-applied inside `prepareSynth` /
    /// sequencer construction, so they survive on their own.
    ///
    /// No-op before the first `prepare(score:)`. Throws whatever `prepare(score:)` throws (in practice only
    /// `engine.start()`); the caller decides what a failure means — see `recordGraphRestartFailure(_:)`.
    ///
    /// This is the *only* sanctioned in-place graph rebuild. Both callers (a SoundFont hot-swap and an audio
    /// configuration change) go through it rather than reconnecting nodes themselves: `prepare(score:)` hard-stops
    /// the engine before it mutates the graph, which is what keeps a live render cycle from faulting on freed
    /// sampler memory.
    func restartGraphPreservingState() throws {
        if let injected = graphRestartFailureForTesting {
            graphRestartFailureForTesting = nil
            throw injected
        }
        guard let score = loadedScore else { return }
        // Snapshot the state `prepare(score:)` would otherwise reset.
        let savedCursor = currentCursor
        let wasPlaying = state == .playing
        let savedMixer = mixerChannels
        // `prepare(score:)` calls `clearLoop()` — an in-place rebuild is not the host asking to drop the loop, so
        // it has to come back. Snapshotted here (score/notated ticks) and re-applied below via the same `apply(loop:)`
        // the public loop setters use, once the transport has been re-seated: applying a loop projects it onto the
        // freshly built sequence map / timeline (`projectLoopOntoTransport`), so it must run AFTER `play(...)` below,
        // not before.
        let savedLoop = loopRange
        try prepare(score: score)
        // `prepare` rebuilds the channel array at the score's defaults;
        // re-apply the user's mixer state.
        for channel in savedMixer {
            setVolume(forChannel: channel.id, to: channel.volume)
            setMuted(forChannel: channel.id, to: channel.isMuted)
            setSoloed(forChannel: channel.id, to: channel.isSoloed)
            if let program = channel.program {
                setProgram(forChannel: channel.id, to: program)
            }
        }
        // `prepare(score:)` reset the sequencer, so building it via
        // `play(from:)` is the only way to re-seat the cursor. Re-pause
        // immediately when we weren't actively playing, so a paused rebuild
        // keeps its place without continuing to sound.
        if wasPlaying {
            // No `usingBackend, backend?.isReady == false` guard needed here, unlike the paused branch below: the
            // resolver is unchanged across a configuration-change / soundfont-reload rebuild (only the graph is
            // rebuilt), so the backend's SoundFont is still the one already loaded, and if `play` is nonetheless
            // deferred for some other reason, the backend's own ready-path replay self-heals it.
            play(from: savedCursor, in: score)
        } else if let savedCursor {
            // With an async-loading backend the play-then-pause dance is unsafe:
            // `play` would DEFER (the SoundFont isn't ready), leaving `state ==
            // .stopped`, so the `if state == .playing` re-pause never fires and the
            // deferred play later starts audibly — a paused rebuild spontaneously
            // resuming. Just keep the position; the next real play resumes from
            // `currentCursor` once the synth is ready.
            if usingBackend, backend?.isReady == false {
                currentCursor = savedCursor
            } else {
                play(from: savedCursor, in: score)
                // Only re-pause if `play` actually started. If the sequencer
                // rebuild failed it left `state == .stopped`; an unconditional
                // `pause()` here would overwrite that with `.paused`, masking
                // the resume failure so the host reads a false "paused and
                // ready" state.
                if state == .playing {
                    pause()
                }
            }
        }
        // AFTER the transport re-seat above: `apply(loop:)` projects the score-tick loop onto the transport via
        // `projectLoopOntoTransport`, which reads `timeline` / `unrolledTimeMap` — both rebuilt by `prepare(score:)`
        // moments ago — so doing this earlier would project against the stale, pre-rebuild timeline.
        if let savedLoop {
            apply(loop: savedLoop)
        }
        graphRestartCount += 1
        lastGraphRestartError = nil
    }

    /// Record an automatic rebuild that failed, and stop the transport lying about it.
    ///
    /// `prepare(score:)` throws only after it has already stopped playback, so `state` is normally `.stopped`
    /// here anyway; the assignment is what guarantees it for every future throw site.
    func recordGraphRestartFailure(_ error: any Error) {
        lastGraphRestartError = error
        state = .stopped
    }

    /// Build the AUMIDISynth unit(s): always a melodic unit (pitched channels), plus a separate percussion unit (GM
    /// channel 9) ONLY when the score has a drum part. The percussion unit lets the melodic unit carry a global
    /// coarse-tuning transpose without re-pitching drums; a drumless score doesn't pay for a second full-SoundFont
    /// load. Loads the GM SoundFont into each built unit, configures pitch-bend on the melodic unit, and applies the
    /// current calibration + transpose.
    private func prepareSynth(score: Score) throws { // swiftlint:disable:this function_body_length
        let url = resolver.defaultGMSoundfontURL
        let plan = LiveChannelPlan.build(score: score)
        liveChannelPlan = plan
        instrumentMIDIChannels = Dictionary(
            uniqueKeysWithValues: plan.strips.map { strip in
                (
                    MixerChannel.Kind.instrument(
                        partIndex: strip.partIndex, ordinal: strip.ordinal,
                    ),
                    UInt8(clamping: strip.liveChannel),
                )
            },
        )
        // Each staff's tick-0 channel is its part's ordinal-0 strip —
        // the LIVE (deduped, single-port) channel, not the rendered
        // SMF's per-instance channel, so cursor / preview addressing
        // stays in sync with what `MidiChannelRemap` puts on the wire.
        let channels: [Int] = score.allStaves.map { entry in
            plan.strip(partIndex: entry.address.partIndex, ordinal: 0)?
                .liveChannel ?? 0
        }

        // Measure tick bases for the switch table. Deliberately the
        // plain duration sum, NOT `MidiRenderer.measureTicks` (which
        // also budgets breath pauses): a tap preview is a UI affordance,
        // and the one-bar imprecision after a breath-pause-bearing
        // measure is inaudible. Playback routing correctness comes from
        // the renderer, which uses its own bases.
        var bases: [Int] = []
        var acc = 0
        for duration in score.effectiveMeasureDurations() {
            bases.append(acc)
            acc += duration.ticks(division: score.division)
        }
        staffChannelSwitches = [:]
        for (idx, entry) in score.allStaves.enumerated() {
            let partIndex = entry.address.partIndex
            let timeline = score.instrumentTimeline(forPart: partIndex)
            guard timeline.count > 1 else { continue }
            staffChannelSwitches[idx] = timeline.enumerated()
                .compactMap { timelineIndex, point in
                    guard bases.indices.contains(point.measureIndex),
                          let ordinal = plan.dedupedOrdinal(
                              partIndex: partIndex,
                              timelineIndex: timelineIndex,
                          ),
                          let strip = plan.strip(
                              partIndex: partIndex, ordinal: ordinal,
                          )
                    else { return nil }
                    return (
                        bases[point.measureIndex]
                            + point.position.ticks(division: score.division),
                        UInt8(clamping: strip.liveChannel),
                    )
                }
                .sorted { $0.0 < $1.0 }
        }

        // SwiftySynth path: one persistent source node + SoundFont reload, no
        // per-channel AU units. Populate the same staff→channel / drum maps the
        // mixer and cursor rely on, then hand the SoundFont + drum channels to
        // the backend.
        if let backend {
            var drumChannels: Set<UInt8> = []
            for (idx, entry) in score.allStaves.enumerated() {
                let part = score.part(at: entry.address)
                let isDrums = part?.instrument.useDrumset == true
                let midiCh = UInt8(
                    clamping: idx < channels.count ? channels[idx] : 0,
                )
                staffMIDIChannels[idx] = midiCh
                staffIsDrum[idx] = isDrums
                if isDrums { drumChannels.insert(midiCh) }
            }
            // Attach + connect once; the node persists across re-prepares
            // (a `reloadSoundfont` only re-loads the SF2 into it).
            if backend.outputNode.engine == nil {
                backend.attach(to: engine)
                engine.connect(
                    backend.outputNode, to: scoreGainMixer, format: nil,
                )
                // Surface async-load progress and run any deferred play on ready.
                backend.onReadyChanged = { [weak self] ready in
                    self?.handleBackendReady(ready)
                }
            }
            // The backend renders the metronome on its own synth, so it needs the
            // resolved click sound too — the AUMIDISynth `MetronomeController`
            // prepared above never sounds on the backend path. The resolver
            // caches its generated SF2, so asking twice costs nothing.
            backend.prepare(
                soundfontURL: url,
                metronomeSoundfontURL: clickResolver.resolvedSoundFontURL(),
                drumChannels: drumChannels,
            )
            // The fresh synth resets tuning/rate; push the engine's persisted
            // A4 calibration, transpose, and playback rate back onto it.
            backend.setTuning(
                cents: masterTuningCents, transposeSemitones: transposeSemitones,
            )
            backend.setRate(pendingRate)
            return
        }

        let hasDrums = score.parts.contains { $0.instrument.useDrumset }

        // Melodic unit — all pitched channels.
        let melodic = MIDISynthBuilder.make()
        engine.attach(melodic)
        engine.connect(melodic, to: scoreGainMixer, format: nil)
        if let url {
            try? MIDISynthBuilder.loadSoundFont(
                into: melodic, url: url, bankMSB: 0, bankLSB: 0, program: 0,
            )
        }
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: melodic, semitones: 12, onChannel: ch,
            )
        }
        melodicSynth = melodic

        // Percussion unit — GM channel 9. Built only when the score has drums (mirrors MetronomeController's
        // separate sampler). Same SF2, drum bank preloaded on channel 9. No pitch-bend, no transpose.
        if hasDrums {
            let percussion = MIDISynthBuilder.make()
            engine.attach(percussion)
            engine.connect(percussion, to: scoreGainMixer, format: nil)
            if let url {
                try? MIDISynthBuilder.loadSoundFont(
                    into: percussion, url: url,
                    bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
                )
            }
            percussionSynth = percussion
        }
        applyTuning()

        for (idx, entry) in score.allStaves.enumerated() {
            let part = score.part(at: entry.address)
            let isDrums = part?.instrument.useDrumset == true
            let midiCh = UInt8(
                clamping: idx < channels.count
                    ? channels[idx] : 0,
            )
            staffMIDIChannels[idx] = midiCh
            staffIsDrum[idx] = isDrums
        }
    }

    /// Briefly play the note identified by `noteID` on the shared
    /// synth using the staff's assigned MIDI channel. Used by the host
    /// when the user clicks / taps a single note — mirrors MuseScore's
    /// "preview on selection" behavior. Calls are non-blocking; the
    /// matching note-off is scheduled on a high-QoS background queue.
    /// Stop and forget any in-flight tap-preview: invalidate the pending end
    /// action (bump the generation), silence every still-sounding preview
    /// channel, and clear tracking. Called on teardown so a ringing preview
    /// can't outlive the synth it played on.
    private func cancelActivePreview() {
        // `silence()` both reports the note to cut and invalidates the end action already scheduled for it.
        // No note-on follows, so All Sound Off (`nextChannel: nil`) is safe.
        cutPreviewNote(previewPolicy.silence(), nextChannel: nil)
        // Also force-stop a held sustained preview so it can't outlive the
        // synth on teardown / reload.
        if let sustained = activeSustainedPreview {
            sustainedStop(sustained)
            activeSustainedPreview = nil
        }
        previewShouldRepauseEngineOnDrain = false
    }

    /// Silence `voice` — the fixed-duration tap preview the policy just gave up, if there was one.
    ///
    /// Shared by `cancelActivePreview()` (full teardown, `nextChannel: nil`) and `previewNoteOn(...)` (a
    /// still-pending tap preview must not survive into a sustained hold). Uses backend `stopNote` when
    /// delegated. Otherwise: when `nextChannel` matches the preview's channel, a plain note-off is used instead
    /// of All Sound Off — CC 120 immediately before a same-channel note-on is swallowed by AUMIDISynth, exactly
    /// the pitfall `playPreview`'s same-channel branch avoids. A different (or `nil`) `nextChannel` uses CC 120
    /// on every attached AU unit, since we don't know here which unit the preview sounded on.
    private func cutPreviewNote(_ voice: PreviewVoice?, nextChannel: UInt8?) {
        guard let voice else { return }
        if let backend {
            backend.stopNote(channel: voice.channel, pitch: voice.pitch)
        } else if voice.channel == nextChannel {
            for unit in attachedSynths {
                unit.stopNote(voice.pitch, onChannel: voice.channel)
            }
        } else {
            for unit in attachedSynths {
                MIDISynthBuilder.sendControlChange(
                    into: unit, controller: 120, value: 0,
                    onChannel: voice.channel,
                )
            }
        }
    }

    /// Stop a held sustained-preview note on whichever synth path is active.
    private func sustainedStop(_ note: (staff: Int, channel: UInt8, pitch: UInt8)) {
        if let backend {
            backend.stopNote(channel: note.channel, pitch: note.pitch)
        } else {
            synth(forStaff: note.staff)?.stopNote(note.pitch, onChannel: note.channel)
        }
    }

    /// SwiftySynth tap-preview: start the note, schedule its note-off after the
    /// melodic `duration` (or the longer drum tail), and restore a host-parked
    /// engine once it drains. Simpler than the AUMIDISynth path — SwiftySynth has
    /// none of the CC120 / same-channel note-swallowing quirks.
    private func backendPlayPreview(
        pitch: UInt8, channel: UInt8, isDrum: Bool,
        duration: TimeInterval, velocity: UInt8,
    ) {
        guard let backend else { return }
        let plan = previewPolicy.begin(
            voice: PreviewVoice(channel: channel, pitch: pitch),
            velocity: velocity,
            isDrum: isDrum,
            ringMilliseconds: Int(duration * 1000),
        )
        if let previous = plan.supersedes {
            backend.stopNote(channel: previous.channel, pitch: previous.pitch)
        }
        if !engine.isRunning {
            try? engine.start()
            if state != .playing { previewShouldRepauseEngineOnDrain = true }
        }
        backend.startNote(channel: channel, pitch: pitch, velocity: velocity)
        previewQueue.asyncAfter(deadline: .now() + plan.ringSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let ending = previewPolicy.end(generation: plan.generation) else { return }
                self.backend?.stopNote(channel: ending.channel, pitch: ending.pitch)
                // A sustained hold started after this tap owns the repause
                // obligation now (see `previewNoteOff`) — leave the flag set
                // and don't pause out from under the still-ringing hold.
                guard previewShouldRepauseEngineOnDrain, activeSustainedPreview == nil else { return }
                // Defer the park until the note-off release has rendered out. Parking
                // the engine right after `stopNote` freezes the software synth's render
                // thread mid-release, clicking off the tail and leaving it frozen to
                // resume on the next preview's `engine.start()`. A newer preview makes
                // this generation stale, cancelling this park and keeping the graph
                // running for the next note.
                previewQueue.asyncAfter(deadline: .now() + plan.releaseTailSeconds) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, previewPolicy.isCurrent(generation: plan.generation) else { return }
                        guard previewShouldRepauseEngineOnDrain, activeSustainedPreview == nil else { return }
                        previewShouldRepauseEngineOnDrain = false
                        if state != .playing, engine.isRunning { engine.pause() }
                    }
                }
            }
        }
    }

    // swiftlint:disable:next function_body_length
    public func playPreview(
        noteID: NoteID,
        in score: Score,
        duration: TimeInterval = 0.3,
        velocity: UInt8 = 96,
    ) {
        guard state != .exporting else { return }
        // An audition is not a claim on the audio route: sound it on a mixing session rather than letting
        // `engine.start()` below re-activate an exclusive one a previous `play(...)` took. No-op when the session is
        // already mixing. See `PlaybackEngine+AudioSession`.
        prepareAudioSessionForPreview()
        guard let pitch = pitch(for: noteID, in: score) else { return }
        let flatIdx = score.allStaves.firstIndex(where: {
            $0.address == noteID.staff
        }) ?? -1
        let tick = absoluteTick(of: noteID, in: score)
        guard let midiChannel = midiChannel(forStaff: flatIdx, atTick: tick) else { return }
        if backend != nil {
            // Re-assert EVERY strip's program + volume on the backend synth
            // before the note-on: a prior playback's sequencer resets the
            // synth's channel state to GM defaults, so without this the
            // audition sounds on program 0 (piano) at the default volume —
            // and re-asserting only this staff's channel would leave every
            // OTHER instrument channel stuck at those GM defaults until its
            // own preview happened to fire. See `reassertBackendChannelState`.
            reassertBackendChannelState()
            backendPlayPreview(
                pitch: pitch, channel: midiChannel,
                isDrum: isDrumStaff(flatIdx),
                duration: duration, velocity: velocity,
            )
            return
        }
        guard let instrument = synth(forStaff: flatIdx) else { return }

        // Cut the previous preview before starting the new one. Bumping the
        // generation invalidates its pending end action so it can't fire late
        // and cut this new note. On a *different* channel use All Sound Off
        // (CC 120) — immediate and ignores release, so it also truncates a
        // ringing cymbal. On the *same* channel use a plain note-off: CC 120
        // right before a note-on on the same channel is swallowed by AUMIDISynth
        // (the next drum tap would be silent), and a drum re-hit overlapping its
        // own decay is natural.
        let isDrum = isDrumStaff(flatIdx)
        let plan = previewPolicy.begin(
            voice: PreviewVoice(channel: midiChannel, pitch: pitch),
            velocity: velocity,
            isDrum: isDrum,
            ringMilliseconds: Int(duration * 1000),
        )
        if let previous = plan.supersedes {
            if previous.channel == midiChannel {
                instrument.stopNote(previous.pitch, onChannel: previous.channel)
            } else {
                MIDISynthBuilder.sendControlChange(
                    into: instrument, controller: 120, value: 0,
                    onChannel: previous.channel,
                )
            }
        }

        // A paused `AVAudioEngine` renders nothing, so resume the graph for the
        // preview; the drain below restores the host-parked state once the
        // preview ends with no follow-up tap.
        if !engine.isRunning {
            try? engine.start()
            if state != .playing {
                previewShouldRepauseEngineOnDrain = true
            }
        }

        instrument.startNote(
            pitch, withVelocity: velocity, onChannel: midiChannel,
        )

        // The policy sets how long it rings — a drum for its decay (the decay is the point), a melodic note for
        // the caller's `duration`. End melodic with a note-off and drums with CC 120 (note-off won't stop a
        // one-shot's decay). The timer fires a plain `@convention(block)` closure (no actor-executor assertion
        // off the main queue); the actual end + drain run on the main actor, and answer `nil` if a newer tap has
        // superseded this one.
        //
        // No `releaseTailSeconds` deferral on this path, unlike the backend's: an AU instrument released cleanly
        // through an engine pause. The plan still carries the number — whether parking the graph would cut a
        // release is a property of the graph, and that is each engine's own to know.
        previewQueue.asyncAfter(deadline: .now() + plan.ringSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, previewPolicy.end(generation: plan.generation) != nil else { return }
                let endInstrument = synth(forStaff: flatIdx)
                if let endInstrument {
                    if isDrum {
                        MIDISynthBuilder.sendControlChange(
                            into: endInstrument, controller: 120, value: 0,
                            onChannel: midiChannel,
                        )
                    } else {
                        endInstrument.stopNote(pitch, onChannel: midiChannel)
                    }
                }
                // A sustained hold started after this tap owns the repause
                // obligation now (see `previewNoteOff`) — leave the flag set
                // and don't pause out from under the still-ringing hold.
                guard previewShouldRepauseEngineOnDrain, activeSustainedPreview == nil else { return }
                previewShouldRepauseEngineOnDrain = false
                // Don't pause a graph that real playback is now driving.
                if state != .playing, engine.isRunning {
                    engine.pause()
                }
            }
        }
    }

    /// Start a *sustained* preview note on `flatStaffIndex`'s own MIDI channel —
    /// so it sounds in the mixer-selected program and the melodic synth's global
    /// tuning (calibration + whole-score transpose), exactly like `playPreview`,
    /// but held until `previewNoteOff(pitch:)` or a superseding `previewNoteOn`.
    /// Resumes a host-parked graph and re-parks it on the matching note-off when
    /// not playing. Intended for use only while stopped/paused (the caller gates
    /// this); the held note shares the staff's sequencer channel, so it is not
    /// meant to overlap live playback. `atTick` auditions the instrument active
    /// at the cursor (see `midiChannel(forStaff:atTick:)`); it defaults to `0`
    /// (the part's opening instrument) so existing callers keep compiling.
    public func previewNoteOn(
        pitch: UInt8, onStaff flatStaffIndex: Int, velocity: UInt8 = 96, atTick tick: Int = 0,
    ) {
        guard state != .exporting else { return }
        // Same as `playPreview`: an audition sounds on a mixing session, never on the exclusive one playback took.
        prepareAudioSessionForPreview()
        guard let midiChannel = midiChannel(forStaff: flatStaffIndex, atTick: tick) else { return }
        // Resolve the AU instrument (AUMIDISynth path only) BEFORE any side
        // effect below, so an invalid staff index bails out cleanly instead of
        // leaving the engine resumed and the prior preview cut with no note
        // to sound. `synth(forStaff:)` is always nil in backend mode.
        let instrument = backend == nil ? synth(forStaff: flatStaffIndex) : nil
        guard backend != nil || instrument != nil else { return }

        // A still-pending fixed-duration tap-preview drain must not pause the
        // engine mid-hold. Invalidate it and cut its note now — with a plain
        // note-off (not CC 120) when it shares this note's channel, since CC
        // 120 immediately before a same-channel note-on is swallowed by
        // AUMIDISynth. The repause obligation (previewShouldRepauseEngineOnDrain)
        // transfers to our own previewNoteOff below.
        cutPreviewNote(previewPolicy.silence(), nextChannel: midiChannel)

        // Cut any prior sustained note first — only one sustained preview is
        // active at a time.
        if let previous = activeSustainedPreview { sustainedStop(previous) }
        activeSustainedPreview = nil

        // A paused `AVAudioEngine` renders nothing; resume it for the preview
        // and let the matching note-off restore the host-parked state.
        if !engine.isRunning {
            try? engine.start()
            if state != .playing { previewShouldRepauseEngineOnDrain = true }
        }

        if let backend {
            // Re-assert EVERY strip's program + volume first — a prior
            // playback reset the synth's channel state to GM defaults (see
            // `reassertBackendChannelState`).
            reassertBackendChannelState()
            backend.startNote(channel: midiChannel, pitch: pitch, velocity: velocity)
        } else if let instrument {
            instrument.startNote(pitch, withVelocity: velocity, onChannel: midiChannel)
        }
        activeSustainedPreview = (flatStaffIndex, midiChannel, pitch)
    }

    /// Stop the sustained preview note for `pitch` (no-op unless it is the
    /// currently held sustained note).
    public func previewNoteOff(pitch: UInt8) {
        guard let active = activeSustainedPreview, active.pitch == pitch else { return }
        sustainedStop(active)
        activeSustainedPreview = nil
        // Restore the host-parked graph if this preview resumed it, playback
        // isn't now driving it, AND no tap preview is still pending — a
        // pending tap's own drain owns the repause obligation until it fires
        // (see the `playPreview` / `backendPlayPreview` drains).
        if previewShouldRepauseEngineOnDrain, previewPolicy.sounding == nil, state != .playing, engine.isRunning {
            previewShouldRepauseEngineOnDrain = false
            engine.pause()
        }
    }

    /// MIDI pitch for the chord-note this `NoteID` references, or
    /// `nil` if the score's structure has changed since the ID was
    /// created (out-of-range index, no longer a chord, etc.).
    private func pitch(
        for noteID: NoteID, in score: Score,
    ) -> UInt8? {
        guard let staff = score[noteID.staff] else { return nil }
        guard noteID.measureIndex < staff.measures.count else {
            return nil
        }
        let measure = staff.measures[noteID.measureIndex]
        guard noteID.voiceIndex < measure.voices.count else {
            return nil
        }
        let voice = measure.voices[noteID.voiceIndex]
        guard noteID.elementIndex < voice.elements.count,
              case let .chord(chord) =
              voice.elements[noteID.elementIndex],
              noteID.noteIndexInChord < chord.notes.count
        else { return nil }
        return UInt8(clamping: chord.notes[noteID.noteIndexInChord].pitch)
    }

    /// Absolute tick of `noteID` within `score`, on the same plain
    /// (non-breath-budgeted) measure tick bases used to build
    /// `staffChannelSwitches` — see `prepareSynth(score:)`. `0` when
    /// the id doesn't resolve to a measure index.
    private func absoluteTick(of noteID: NoteID, in score: Score) -> Int {
        let inMeasure = score.resolveTickInMeasure(for: .note(noteID)) ?? 0
        let durations = score.effectiveMeasureDurations()
        guard durations.indices.contains(noteID.measureIndex) else { return inMeasure }
        var base = 0
        for i in 0 ..< noteID.measureIndex {
            base += durations[i].ticks(division: score.division)
        }
        return base + inMeasure
    }

    // MARK: - Full playback

    /// Begin playing the score from `from` (or from the start when
    /// `from == nil`). The first call lazily builds the sequencer
    /// from the score's MIDI rendering and routes each track to
    /// its matching staff sampler. Subsequent calls just rewind /
    /// re-position the existing sequencer, which keeps re-press of
    /// Space / the play button cheap.
    ///
    /// When `countIn` is true and the score yields a non-degenerate
    /// count-in schedule, a metronome pre-roll is prepended to the
    /// sequence: clicks sound for one prepended measure (plus any
    /// anacrusis / mid-measure lead-in), the cursor is pinned at the
    /// start position, and real playback begins once the pre-roll
    /// completes. See `SequenceMap` / `PreRollSequenceAssembler`.
    public func play( // swiftlint:disable:this function_body_length
        from cursor: ScoreCursor? = nil, in score: Score, countIn: Bool = false,
    ) {
        guard state != .exporting else { return }
        guard let timeline else { return }
        // A `.mixUntilPlay` host has been sharing output with whatever else was playing since `prepare(score:)`; this
        // is the moment it asked for playback, so take the session exclusively. Ahead of both transport paths and of
        // the not-ready deferral below, so the claim lands on the user's press rather than on the SoundFont finishing
        // to load. No-op under the other policies. See `PlaybackEngine+AudioSession`.
        escalateAudioSessionForPlayback()
        if usingBackend {
            if let backend, !backend.isReady {
                // SoundFont still loading — remember the request and start it the
                // moment the synth lands (see `handleBackendReady`).
                pendingBackendPlay = (cursor, score, countIn)
                return
            }
            backendPlay(
                from: cursor, in: score, countIn: countIn, timeline: timeline,
            )
            return
        }
        do {
            // Nil-cursor parity with `positionForNormalPlay`: while not stopped, a nil cursor means
            // "resume from the current position"; only when stopped does it mean "from the top". A
            // count-in play (and any forced rebuild) can't inherit the sequencer's retained beat — the
            // sequence is re-anchored / freshly built at 0 — so it anchors at the engine's own
            // `currentCursor`, which survives `pause()` and is nil after `stop()`. Without this, a
            // resume-with-count-in (a host that passes nil on resume, as the normal path allows) would
            // restart at m1.
            let startCursor = Self.effectiveStartCursor(
                cursor: cursor, isStopped: state == .stopped, currentCursor: currentCursor,
            )
            let plan = countIn
                ? CountInBeats.compute(score: score, startCursor: startCursor)
                : nil
            var didRebuildNormal = false
            if let plan {
                // Count-in sequences are start-specific (the shift depends on
                // `baseTick`), so they are rebuilt on every count-in play.
                let baseTick = startCursor
                    .flatMap { timeline.frame(forCursor: $0)?.tick } ?? 0
                sequenceMap = SequenceMap(
                    preRollTicks: plan.preRollTicks, baseTick: baseTick,
                )
                try buildCountInSequencer(
                    for: score, plan: plan, baseTick: baseTick,
                )
                sequencerHasPreRoll = true
                sequencerScore = score
            } else if sequencer == nil || sequencerScore != score
                || sequencerHasPreRoll
            {
                // Normal build. A prior count-in leaves `sequencerHasPreRoll`
                // set, forcing a rebuild here so the shifted sequence is never
                // reused as an un-shifted one.
                sequenceMap = .identity
                try buildSequencer(for: score)
                sequencerHasPreRoll = false
                sequencerScore = score
                didRebuildNormal = true
            }
            guard let sequencer else { return }
            // Resume the audio graph if a previous `pause()` paused it.
            // `AVAudioEngine.start()` is the documented resume path after
            // `pause()`; safe no-op if already running.
            if !engine.isRunning {
                try engine.start()
            }
            if sequencerHasPreRoll {
                // Start at the pre-roll origin (sequencer tick 0) and pin the
                // cursor at the start position so it shows immediately — it
                // stays put until the pre-roll completes and real playback
                // crosses into the shifted score content.
                sequencer.currentPositionInBeats = 0
                currentCursor = startCursor
                    .flatMap { timeline.frame(forCursor: $0)?.cursor }
                    ?? timeline.frame(atTick: sequenceMap.baseTick)?.cursor
            } else {
                // A forced rebuild (leaving a prior count-in) yields a fresh sequencer parked at beat
                // 0; feed it the effective resume cursor so a nil cursor doesn't silently restart at
                // m1. The reuse path keeps passing the raw `cursor` so exact mid-note beat retention
                // (nil → stay put) is untouched.
                positionForNormalPlay(
                    cursor: didRebuildNormal ? startCursor : cursor,
                    timeline: timeline, sequencer: sequencer,
                )
            }
            // Re-assert pitch-bend sensitivity NOW that the engine is
            // running, the sequencer is loaded, and tracks are routed
            // to the shared synth — but BEFORE the sequencer fires its
            // tick-0 events. Without this the SMF's own RPN setup loses
            // a race with the first portamento on the very first play
            // after `prepare(score:)`, leaving the bend clamped at the
            // AU's ±2-semitone default. See
            // `MIDISynthBuilder.setPitchBendSensitivity` for why the
            // C-API path matters.
            if let melodicSynth {
                for ch: UInt8 in 0 ..< 16 where ch != 9 {
                    MIDISynthBuilder.setPitchBendSensitivity(
                        into: melodicSynth, semitones: 12, onChannel: ch,
                    )
                }
            }
            try sequencer.start()
            // The SMF's tick-0 events fire on every start / seek-to-0
            // and override anything the mixer set previously. Re-apply
            // program selection + volume / mute / solo here so user
            // mixer choices survive replays and also pause→change→play
            // sequences (where the picker fires while the render thread
            // isn't running).
            reapplyMixerPrograms()
            applyMixerState()
            state = .playing
            startCursorTimer()
        } catch {
            // Don't crash on playback failures; reset to stopped
            // and let the host surface the error if it cares.
            state = .stopped
        }
    }

    /// Backend async-load readiness changed. Mirror it into `isPreparingSoundfont`
    /// and, once ready, start any play deferred while the SoundFont was loading.
    private func handleBackendReady(_ ready: Bool) {
        isPreparingSoundfont = !ready
        guard ready, let pending = pendingBackendPlay else { return }
        pendingBackendPlay = nil
        play(from: pending.cursor, in: pending.score, countIn: pending.countIn)
    }

    /// SwiftySynth playback path — a compact equivalent of the AVAudioSequencer
    /// build in `play(...)`. Reuses the assembled + post-processed SMF and the
    /// backend-agnostic `PlaybackTimeline`; loop wrap stays host-driven in
    /// `backendTickCursor`.
    ///
    /// Count-in: the score's own SMF is left un-shifted and the count is played
    /// by the METRONOME transport, which the backend starts ahead of the score
    /// (`play(afterCountInSeconds:)`). That keeps every score-tick read — seek,
    /// loop wrap, end detection, the cursor — in one coordinate space, so a
    /// count-in composes with an active loop instead of being suppressed by it,
    /// and it puts the click on the metronome synth, which is the one holding
    /// the host's click SoundFont. See `startBackendCountIn`.
    private func backendPlay(
        from cursor: ScoreCursor?, in score: Score, countIn: Bool,
        timeline: PlaybackTimeline,
    ) {
        guard let backend else { return }
        do {
            let startCursor = Self.effectiveStartCursor(
                cursor: cursor, isStopped: state == .stopped,
                currentCursor: currentCursor,
            )
            // Resolve the start tick (loop-clamped) once, before deciding on a
            // count-in: with a loop active, playback begins at the loop's start,
            // so that — not the stale cursor outside it — is what to count into.
            var targetTick = startCursor
                .flatMap { timeline.frame(forCursor: $0)?.tick }
            if state == .stopped, targetTick == nil { targetTick = 0 }
            if let loop = loopRange {
                let probe = targetTick ?? backend.currentTick
                if probe < loop.startTick || probe >= loop.endTick {
                    targetTick = loop.startTick
                }
            }
            let rendered = try cachedRender(score)

            if countIn {
                let baseTick = targetTick ?? backend.currentTick
                let countInCursor = timeline.frame(atTick: baseTick)?.cursor ?? startCursor
                if let plan = CountInBeats.compute(
                    score: score, startCursor: countInCursor,
                ) {
                    try startBackendCountIn(
                        backend: backend, score: score, plan: plan,
                        baseTick: baseTick, rendered: rendered, timeline: timeline,
                    )
                    return
                }
            }

            // Normal build. Reload the score transport only when the score
            // changed; a prior count-in leaves the score SMF untouched, so only
            // its metronome sequence has to be swapped back.
            if sequencerScore != score {
                loadBackendNormalSequence(
                    backend: backend, score: score,
                    rendered: rendered, timeline: timeline,
                )
            } else if backendMetronomeHasPreRoll {
                loadBackendMetronomeSequence(
                    backend: backend, rendered: rendered,
                )
            }
            backend.setMetronomeMuted(!metronome.isEnabled)
            if !engine.isRunning { try engine.start() }
            if let tick = targetTick {
                backend.seek(toTick: tick)
                currentCursor = timeline.frame(atTick: tick)?.cursor
            }
            backend.play()
            reapplyMixerPrograms()
            applyMixerState()
            state = .playing
            startCursorTimer()
        } catch {
            state = .stopped
        }
    }

    /// Load the normal (un-shifted) score + metronome transports for a backend
    /// play. The body metronome always plays on the SEPARATE metronome
    /// transport, never baked into the score SMF — that is what lets
    /// `setMetronomeMuted` toggle it live without a reload.
    private func loadBackendNormalSequence(
        backend: any SynthBackend, score: Score,
        rendered: MidiFile, timeline: PlaybackTimeline,
    ) {
        backend.loadSequence(
            PreRollSequenceAssembler.assembleNormal(
                rendered: rendered, metronomeBeats: [],
                mixerManagedChannels: mixerManagedChannels,
            ),
            timeline: timeline,
        )
        // The sequence just loaded is the unrolled render; hand over the projection that turns the
        // engine's notated ticks into positions on it before any transport move can happen.
        backend.setUnrolledTimeMap(unrolledTimeMap)
        loadBackendMetronomeSequence(backend: backend, rendered: rendered)
        sequencerScore = score
        sequenceMap = .identity
    }

    /// (Re)load the plain body metronome — no count-in, no offset.
    private func loadBackendMetronomeSequence(
        backend: any SynthBackend, rendered: MidiFile,
    ) {
        backend.loadMetronomeSequence(
            PreRollSequenceAssembler.metronomeOnly(
                rendered: rendered, metronomeBeats: metronomeBeats,
            ),
            offsetSeconds: 0,
        )
        backendMetronomeHasPreRoll = false
    }

    /// Load + start a count-in playback the way the Android engine does it: the
    /// score's SMF is the ordinary un-shifted build, and the count lives
    /// entirely on the metronome transport — `plan.beats` fill `[0,
    /// preRollTicks)` ahead of the body's own clicks. The backend parks the
    /// score transport at the start position and holds it for `preRollSeconds`
    /// while that transport counts (`play(afterCountInSeconds:)`).
    ///
    /// Two bugs died with the older design, which shifted the score SMF behind a
    /// click track baked into it:
    ///
    ///   * the baked click sounded on the SCORE synth, i.e. in the score's
    ///     SoundFont — GM wood blocks, not the host's click samples, which only
    ///     the metronome synth loads;
    ///   * every score-tick read (seek, loop wrap) had to be translated out of
    ///     the shifted space, so a count-in was simply suppressed whenever a
    ///     loop was active — including "repeat whole score".
    ///
    /// The metronome transport ends up running `offsetSeconds` ahead of the
    /// score's for the rest of the playback (its SMF carries a pre-roll the
    /// score's does not); the backend adds that to its own metronome seeks.
    private func startBackendCountIn(
        backend: any SynthBackend, score: Score, plan: CountInBeats.Result,
        baseTick: Int, rendered: MidiFile, timeline: PlaybackTimeline,
    ) throws {
        let preRollSeconds = Double(plan.preRollTicks)
            * (60.0 / plan.quarterBpm) / Double(timeline.division)
        if sequencerScore != score {
            loadBackendNormalSequence(
                backend: backend, score: score,
                rendered: rendered, timeline: timeline,
            )
        }
        if !engine.isRunning { try engine.start() }
        // Park the score transport at the start position FIRST: `seek` moves both
        // transports, and the metronome's own load right after re-parks it at
        // tick 0 — the first click of the count.
        backend.seek(toTick: baseTick)
        backend.loadMetronomeSequence(
            PreRollSequenceAssembler.metronomeOnly(
                rendered: rendered, metronomeBeats: metronomeBeats,
                plan: plan, baseTick: baseTick, includingPreRollClicks: true,
            ),
            // Where the body's `baseTick` sits on the metronome's clock, minus
            // where it sits on the score's. Both transports run on the UNROLLED
            // render's seconds — which is also where `SynthBackend.seek(toTick:)`
            // puts the score transport — so the subtrahend is projected too, or the
            // click track drifts from the music by the unrolled sequence's head start.
            offsetSeconds: preRollSeconds - unrolledTimeMap.unrolledSeconds(
                fromNotated: timeline.seconds(atTick: Double(baseTick)),
            ),
        )
        backendMetronomeHasPreRoll = true
        backend.setMetronomeMuted(!metronome.isEnabled)
        currentCursor = timeline.frame(atTick: baseTick)?.cursor
        backend.play(afterCountInSeconds: preRollSeconds)
        reapplyMixerPrograms()
        applyMixerState()
        state = .playing
        startCursorTimer()
    }

    /// Position the sequencer for a normal (no count-in) play. Runs only with
    /// `sequenceMap == .identity`, so raw sequencer ticks equal score ticks and
    /// no translation is needed here. Extracted verbatim from the pre-count-in
    /// `play` so the normal path is behavior-for-behavior unchanged.
    private func positionForNormalPlay(
        cursor: ScoreCursor?, timeline: PlaybackTimeline, sequencer: AVAudioSequencer,
    ) {
        // Position by beats. `currentPositionInSeconds` is derived from beats
        // using the player's current tempo (not the tempo map), so seeking via
        // seconds on a tempo-curved score lands at the wrong tick. Beats /
        // ticks bypass that.
        //
        // `targetTick == nil` means "resume from the paused position" — leave
        // the sequencer's beat alone unless a loop snap forces a move.
        var targetTick: Int?
        if let cursor, let frame = timeline.frame(forCursor: cursor) {
            targetTick = frame.tick
        } else if state == .stopped {
            targetTick = 0
        }
        if let loop = loopRange {
            let probeTick = targetTick ?? Int(
                (
                    sequencer.currentPositionInBeats
                        * Double(timeline.division)
                ).rounded(),
            )
            if probeTick < loop.startTick
                || probeTick >= loop.endTick
            {
                targetTick = loop.startTick
            }
        }
        if let t = targetTick {
            // `t` is a notated tick; the sequencer's position is on the unrolled render.
            sequencer.currentPositionInBeats =
                Double(unrolledTick(forNotated: t)) / Double(timeline.division)
            currentCursor = timeline.frame(atTick: t)?.cursor
        }
    }

    /// Reposition the playback cursor without changing play / pause
    /// state. Used for click-to-seek during playback — the user taps
    /// a note and audio jumps to that note while continuing to play.
    /// No-op when there is no sequencer yet (call `prepare(score:)`
    /// first) or when `cursor` doesn't resolve into the timeline.
    public func seek(to cursor: ScoreCursor) {
        guard state != .exporting else { return }
        guard let timeline, let frame = timeline.frame(forCursor: cursor) else { return }
        // Keep a play that's waiting on the SoundFont load anchored at the latest
        // seek, so the deferred play doesn't start at a now-stale cursor.
        if pendingBackendPlay != nil { pendingBackendPlay?.cursor = cursor }
        let tick = snapTickToLoop(frame.tick)
        if let backend {
            // The score transport is never shifted on this path, so a seek is a
            // plain score-tick seek (which also ends any count-in still owed —
            // see `SwiftySynthBackend.seek`). Only the metronome sequence can
            // still be a count-in build; swap it back for the plain one so a
            // target before the count-in's start position gets its clicks too.
            if backendMetronomeHasPreRoll, let score = sequencerScore,
               let rendered = try? cachedRender(score)
            {
                loadBackendMetronomeSequence(backend: backend, rendered: rendered)
                backend.setMetronomeMuted(!metronome.isEnabled)
            }
            backend.seek(toTick: tick)
            // Re-assert the mixer for the same reason the pre-roll branch above, the loop wrap in
            // `backendTickCursor`, and every backend `play` do: a transport reposition resets the
            // synth's channels to GM defaults (SwiftySynth's `MidiFileSequencer.seek` calls
            // `Synthesizer.reset()`), and the tick-0 CC 7 / programChange that would otherwise be
            // chased back are STRIPPED for mixer-managed channels in `postProcessForMIDISynth` —
            // precisely so the mixer stays the sole authority. Without this the user's balance
            // (and each staff's program) silently reverts to CC 7 = 100 / program 0 on every seek:
            // the host's seek bar, the lock-screen scrubber, and the ±10 s skip all land here.
            reapplyMixerPrograms()
            applyMixerState()
            currentCursor = timeline.frame(atTick: tick)?.cursor
            return
        }
        // An active count-in sequence only holds score content from `baseTick` onward — the pre-roll
        // shift dropped everything earlier. A seek target before `baseTick` is unreachable in this
        // sequence: `sequencerTick(fromScore:)` maps it into (or before) the pre-roll region, which
        // would replay the count-in and resume from `baseTick` instead of the target. While playing,
        // rebuild the plain un-shifted sequence anchored at the target and keep playing — a seek must
        // never insert a count-in. (Paused seeks are left as-is: the next play rebuilds from the
        // effective start cursor regardless, so the stale sequencer position is never heard.)
        //
        // Crucially, `self.sequencer` is NOT captured in a local before this branch: `play` →
        // `buildSequencer` stops + nils the old sequencer before creating its replacement, and a
        // lingering strong ref here would defeat that and reintroduce the two-sequencer overlap.
        if state == .playing, sequencerHasPreRoll, tick < sequenceMap.baseTick,
           let score = sequencerScore
        {
            play(from: cursor, in: score, countIn: false)
            return
        }
        guard let sequencer else { return }
        // `sequencerTick(fromScore:)` shifts by the count-in pre-roll only — its input is already
        // a position on the unrolled render, so the notated tick has to be projected first.
        sequencer.currentPositionInBeats =
            Double(sequenceMap.sequencerTick(fromScore: unrolledTick(forNotated: tick)))
            / Double(timeline.division)
        currentCursor = timeline.frame(atTick: tick)?.cursor
    }

    /// Loop the half-open region `[start, end)` — playback wraps at
    /// `end`'s onset tick (the item under `end` is NOT sounded). Use
    /// `setLoop(from:throughEndOf:)` to include the last item's full
    /// ringing duration.
    ///
    /// No-op when `start`/`end` don't resolve in the current timeline,
    /// when `start >= end`, or when no sequencer has been built yet.
    public func setLoop(from start: ScoreCursor, to end: ScoreCursor) {
        guard state != .exporting else { return }
        guard let timeline,
              let s = timeline.frame(forCursor: start),
              let e = timeline.frame(forCursor: end),
              s.tick < e.tick
        else { return }
        apply(loop: LoopRange(startTick: s.tick, endTick: e.tick))
    }

    /// Loop from `start` through the *end* of `last`'s notated
    /// duration — i.e. the loop wraps once playback has finished
    /// sounding `last`. Equivalent to a half-open `[start, lastEnd)`
    /// region, where `lastEnd` is `last`'s onset tick + its duration
    /// (read from `PlaybackTimeline.itemEndTicks`).
    ///
    /// Use this when looping a range *selection* on the score: the
    /// user expects the last selected note to ring before the loop
    /// wraps, which `setLoop(from:to:)` cuts short.
    public func setLoop(
        from start: ScoreCursor, throughEndOf last: ScoreItemID,
    ) {
        guard state != .exporting else { return }
        guard let timeline,
              let s = timeline.frame(forCursor: start),
              let endTick = timeline.itemEndTicks[last],
              s.tick < endTick
        else { return }
        apply(loop: LoopRange(startTick: s.tick, endTick: endTick))
    }

    /// Disable looping. The next `tickCursor` tick stops snapping the
    /// playhead back to `startTick`, so playback continues past the
    /// previous loop end.
    public func clearLoop() {
        guard state != .exporting else { return }
        loopRange = nil
        transportLoop = nil
    }

    private func apply(loop: LoopRange) {
        loopRange = loop
        transportLoop = projectLoopOntoTransport(loop)
    }

    /// `loopRange` expressed in the transport's own coordinates.
    ///
    /// `LoopRange` is a region of the SCORE, so it is stored — and handed back to the host — in
    /// notated ticks. The transport plays the UNROLLED render, where the same music can sit at
    /// several positions (one per pass) and generally none of them is the notated tick. Every
    /// comparison against a polled transport position therefore has to use this instead.
    /// Internal rather than private so `wrapToLoopStart` — itself internal, so tests can drive one
    /// wrap deterministically — can take it, and so a test can assert the projection directly.
    struct TransportLoop: Equatable {
        /// Unrolled tick of the loop's start — its FIRST occurrence in playback order, matching
        /// the rule the rest of scheduling follows.
        let startTick: Int
        /// Exclusive unrolled end. Derived as `startTick + notated span` rather than by looking the
        /// notated end tick up on its own: within one measure-play the region is contiguous and
        /// slope-1, whereas the end tick's own first occurrence can belong to a LATER pass (a loop
        /// over a repeated bar would then swallow the repeat's second take).
        let endTick: Int
        /// The same two bounds on the transport's seconds clock, for a time-based backend. The
        /// span is taken from the notated clock for the same reason: a pass replays its own
        /// stretch of the tempo map, so its duration is the notated one.
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
    }

    private(set) var transportLoop: TransportLoop?

    private func projectLoopOntoTransport(_ loop: LoopRange) -> TransportLoop? {
        guard let timeline else { return nil }
        let startTick = unrolledTick(forNotated: loop.startTick)
        let notatedStartSeconds = timeline.seconds(atTick: Double(loop.startTick))
        let notatedEndSeconds = timeline.seconds(atTick: Double(loop.endTick))
        let startSeconds = unrolledTimeMap.unrolledSeconds(fromNotated: notatedStartSeconds)
        return TransportLoop(
            startTick: startTick,
            endTick: startTick + (loop.endTick - loop.startTick),
            startSeconds: startSeconds,
            endSeconds: startSeconds + (notatedEndSeconds - notatedStartSeconds),
        )
    }

    /// The UNROLLED transport tick a NOTATED score tick sits at — its first occurrence in playback
    /// order, which is the coordinate scheduling (seek, play-from, loop wrap) targets. Identity for
    /// a score with no repeat plan.
    ///
    /// The rule itself lives on `PlaybackUnroll` so the Android engine reaches the same one through
    /// JNI (`nativeUnrolledTickForNotated`) instead of restating it in Kotlin.
    private func unrolledTick(forNotated tick: Int) -> Int {
        unroll.firstUnrolledTick(forNotated: tick)
    }

    /// Clamp `tick` into the active loop region. Returns `tick`
    /// unchanged when no loop is set or the tick is already inside.
    private func snapTickToLoop(_ tick: Int) -> Int {
        guard let loop = loopRange else { return tick }
        if tick < loop.startTick || tick >= loop.endTick {
            return loop.startTick
        }
        return tick
    }

    /// Current playback position in seconds, derived from the
    /// sequencer's beat clock against the score's tempo map (not the
    /// sequencer's `currentPositionInSeconds`, which uses the
    /// instantaneous tempo and drifts on tempo-curved scores). Zero
    /// when no sequencer has been built yet.
    ///
    /// During A-B loop playback the raw `currentPositionInBeats` keeps
    /// advancing monotonically — only per-track `loopRange` wraps, not
    /// the sequencer's beat counter (same caveat that drives
    /// `tickCursor`'s modulo fold). Mirror that fold here so callers
    /// observing this property — including the iOS lock-screen
    /// scrubber via `MPNowPlayingInfoPropertyElapsedPlaybackTime` —
    /// see the wrapped, audible position rather than a value that
    /// climbs past the loop end and saturates at score end.
    ///
    /// The AUMIDISynth branch folds inline below; the backend branch folds in seconds via
    /// `foldSecondsForLoop`, since its clock is time-based.
    public var currentTimeSeconds: TimeInterval {
        guard let timeline else { return 0 }
        if let backend {
            // Snapped to the frame's onset, matching the AUMIDISynth branch below. The
            // position comes from the transport's own seconds clock rather than
            // `backend.currentTick`: that tick is a notated `frame(atTime:)` lookup of an
            // UNROLLED position, so it both runs ahead on a repeat score and saturates on the
            // last frame at the end of the piece — freezing the host's scrubber.
            return timeline.frame(
                atTime: backendNotatedSeconds(backend, timeline: timeline),
            )?.timeSeconds ?? 0
        }
        guard let sequencer else { return 0 }
        // Guard the `Double → Int` conversion: a non-finite / out-of-range
        // `currentPositionInBeats` (see `tickCursor`) would otherwise trap.
        // Report 0 for an unusable read rather than crash a lock-screen scrubber.
        guard let rawSeqTick = Int(
            exactly: (sequencer.currentPositionInBeats * Double(timeline.division))
                .rounded(),
        ) else { return 0 }
        // Translate to score ticks; during the pre-roll (`nil`) the cursor is
        // pinned at the start, so report the start position's time via
        // `baseTick`.
        let rawTick = sequenceMap.scoreTick(fromSequencer: rawSeqTick)
            ?? sequenceMap.baseTick
        let tick: Int
        // `rawTick` is an UNROLLED sequencer tick, so the fold has to use the loop's unrolled
        // bounds; folding against the notated ones wrapped at the wrong instant — and by the
        // wrong length — on any score with a repeat.
        if let loop = transportLoop, rawTick >= loop.endTick {
            let len = loop.endTick - loop.startTick
            tick = loop.startTick + (rawTick - loop.startTick) % len
        } else {
            tick = rawTick
        }
        return timeline.frame(
            atTick: unroll.notatedTick(fromUnrolled: tick),
        )?.timeSeconds ?? 0
    }

    /// Like `currentTimeSeconds` but interpolated *within* the current
    /// timeline frame rather than snapped to the frame's onset, so a
    /// caller driving a smooth scroll (a moving pitch trail, a
    /// high-resolution playhead) gets a continuous value instead of one
    /// that steps once per note/beat. Same tempo-map fidelity and A-B
    /// loop fold as `currentTimeSeconds`; the only difference is the
    /// unrounded tick fed to `PlaybackTimeline.seconds(atTick:)`.
    public var currentTimeSecondsContinuous: TimeInterval {
        guard let timeline else { return 0 }
        if let backend {
            // The transport's seconds clock is already continuous, so this needs no frame
            // lookup at all — reading it through `backend.currentTick` was what quantized it
            // to note onsets (and made it unroll-blind and saturating along the way).
            return backendNotatedSeconds(backend, timeline: timeline)
        }
        guard let sequencer else { return 0 }
        // A non-finite `currentPositionInBeats` (see `tickCursor`) would poison
        // the tick math and any downstream `Int` conversion; report 0 instead.
        let beats = sequencer.currentPositionInBeats
        guard beats.isFinite else { return 0 }
        return timelineSeconds(forBeats: beats, timeline: timeline)
    }

    /// Timeline-space seconds for a raw sequencer beat position: pre-roll clamp, A-B loop fold, unroll
    /// translation, tempo-map lookup. Extracted so `currentTimeSecondsContinuous` and `timedPosition`
    /// cannot drift apart — the whole value of the pairing is that both components describe the same beat.
    private func timelineSeconds(forBeats beats: Double, timeline: PlaybackTimeline) -> TimeInterval {
        let rawSeqTick = beats * Double(timeline.division)
        // Translate to score ticks; during the pre-roll clamp to `baseTick`
        // (the pinned start position). Identity map ⇒ pass-through.
        let rawTick: Double = rawSeqTick < Double(sequenceMap.preRollTicks)
            ? Double(sequenceMap.baseTick)
            : Double(sequenceMap.baseTick) + (rawSeqTick - Double(sequenceMap.preRollTicks))
        let tick: Double
        // Unrolled bounds, for the same reason as `currentTimeSeconds`'s fold above.
        if let loop = transportLoop, rawTick >= Double(loop.endTick) {
            let len = Double(loop.endTick - loop.startTick)
            tick = Double(loop.startTick)
                + (rawTick - Double(loop.startTick))
                .truncatingRemainder(dividingBy: len)
        } else {
            tick = rawTick
        }
        return timeline.seconds(atTick: unroll.notatedTick(fromUnrolled: tick))
    }

    /// Current playback position paired with the host-clock instant that position is (or was) rendered at.
    ///
    /// Both components describe the SAME beat: the beat is read once, and its host time comes from
    /// `AVAudioSequencer.hostTimeForBeats:`, which translates through the sequence's own tempo map from the
    /// player's starting beat and time. There is therefore no interval between two reads to be wrong about —
    /// unlike sampling a node's `lastRenderTime` next to a separately-read position, which admits up to one
    /// IO buffer (~23 ms) of unknown error. A host needing to align an independently captured recording
    /// against this playback (VocalTuner's recorded takes) can project the score's time-0 instant onto the
    /// shared host clock from a single read of this property.
    ///
    /// `nil` when the sequencer has not been built, is not playing, or `hostTimeForBeats:` refuses the beat
    /// (documented: it errors when the player is stopped or the beat precedes the player's starting beat).
    /// Also `nil` on an injected `SynthBackend` transport, which has no equivalent pairing yet — its
    /// `AVAudioSourceNode` render block could provide one, but that is a separate change.
    ///
    /// There is a second, undocumented failure mode: right at score-playback start,
    /// `AVAudioSequencer.isPlaying` can report `true` while the underlying `MusicPlayer` has not yet
    /// reached a playing state, and `hostTimeForBeats:error:` RAISES an Objective-C exception in that
    /// window instead of populating its `NSError **` (`error -10852`,
    /// `kAudioToolboxErr_InvalidPlayerState` — see `CSequencerHostTime.h` for the device syslog
    /// evidence). Swift cannot catch an NSException, and no pre-call guard can close the race either:
    /// `isPlaying` is itself the check that lies, and the player's state can change between any check
    /// and the call. The call is therefore routed through `SSMSequencerHostTimeForBeats`, a small
    /// Objective-C shim that wraps it in `@try`/`@catch` and folds both the raising path and the
    /// documented error-pointer path into a single failure result — so this property keeps its
    /// contract of returning `nil`, never a wrong number, whenever a pairing is unavailable.
    public var timedPosition: (timeSeconds: TimeInterval, hostSeconds: TimeInterval)? {
        guard backend == nil, let timeline, let sequencer, sequencer.isPlaying else { return nil }
        let beats = sequencer.currentPositionInBeats
        guard beats.isFinite else { return nil }
        var hostTime: UInt64 = 0
        guard SSMSequencerHostTimeForBeats(sequencer, beats, &hostTime) else { return nil }
        return (
            timelineSeconds(forBeats: beats, timeline: timeline),
            AVAudioTime.seconds(forHostTime: hostTime),
        )
    }

    /// Total playable duration in seconds for the loaded score.
    /// Zero before `prepare(score:)` runs.
    public var totalTimeSeconds: TimeInterval {
        timeline?.totalSeconds ?? 0
    }

    /// Skip playback forward (`seconds > 0`) or backward
    /// (`seconds < 0`) relative to the current position, clamped to
    /// `[0, totalTimeSeconds]`. Preserves play / pause state — when
    /// playing, restarts the transport at the new position so audio
    /// keeps flowing; when paused, just moves the cursor and the next
    /// `play()` resumes from there. No-op before the transport is built.
    public func skip(by seconds: TimeInterval) {
        guard state != .exporting else { return }
        guard let timeline else { return }
        let now = currentTimeSeconds
        let target = max(0, min(timeline.totalSeconds, now + seconds))
        guard let frame = timeline.frame(atTime: target) else { return }
        // Injected-backend path: the AUMIDISynth `sequencer` is never built (see `play`), so a
        // `guard let sequencer` above would make every skip a silent no-op — the host's seek bar,
        // the lock-screen scrubber (`changePlaybackPositionCommand`), and the ±N-second skip all
        // dead. Route the resolved frame through `seek(to:)`, which owns the backend transport move
        // (playing → keeps flowing from the new position; paused → the next `play` resumes there)
        // plus the count-in pre-roll drop, loop snap, and `currentCursor` update — exactly as
        // click-to-seek does.
        if usingBackend {
            seek(to: frame.cursor)
            return
        }
        guard let sequencer else { return }
        if state == .playing, let score = sequencerScore {
            // Mirror `play(from:in:)` semantics — writing
            // `currentPositionInBeats` while the sequencer is running
            // halts it and freezes the cursor timer on its next tick.
            play(from: frame.cursor, in: score)
        } else {
            let tick = snapTickToLoop(frame.tick)
            sequencer.currentPositionInBeats =
                Double(sequenceMap.sequencerTick(fromScore: unrolledTick(forNotated: tick)))
                / Double(timeline.division)
            currentCursor = timeline.frame(atTick: tick)?.cursor
        }
    }

    /// Seek to an absolute time in seconds, clamped to
    /// `[0, totalTimeSeconds]`. Preserves play / pause state — when
    /// playing, restarts the sequencer at the new position; when
    /// paused, moves the cursor and the next `play()` resumes from
    /// there. No-op when no sequencer is built or when `state` is
    /// `.exporting`.
    ///
    /// Provided alongside `skip(by:)` for natural integration with
    /// `MPRemoteCommandCenter.changePlaybackPositionCommand`, whose
    /// handler receives an absolute target time. Internally reuses
    /// `skip(by:)`'s clamp + state-preserve machinery — no new code
    /// path through the sequencer.
    public func seek(toTimeSeconds seconds: TimeInterval) {
        skip(by: seconds - currentTimeSeconds)
    }

    /// Pause playback at the current position. `play(...)` resumes
    /// from there.
    ///
    /// Also pauses the underlying `AVAudioEngine`. Stopping just the
    /// sequencer leaves the engine running and rendering, which iOS
    /// Control Center reads as "audio is still active" and uses to
    /// override `MPNowPlayingInfoCenter.playbackState` — the visible
    /// symptom is the CC pause button briefly flipping to play and
    /// then snapping back to pause after a single tap.
    public func pause() {
        guard state != .exporting else { return }
        // Abandon a play that was waiting on the SoundFont load — the user paused.
        pendingBackendPlay = nil
        if let backend {
            backend.pause()
        } else {
            sequencer?.stop()
            silenceSoundingVoices()
        }
        stopCursorTimer()
        if engine.isRunning {
            engine.pause()
        }
        state = .paused
    }

    /// The AU path's half of "a transport stop leaves nothing sounding" — All Sound Off on every channel of every
    /// attached unit. The backend path does it inside `SynthBackend.pause()` / `stop()`, whose doc comment carries
    /// the reasoning; there is no equivalent seam here, because `AVAudioSequencer.stop()` is Apple's.
    ///
    /// **Why a transport stop needs this at all.** Stopping the sequencer stops event dispatch, so the note-offs
    /// belonging to whatever was sounding at that instant are never sent — those voices stay in their sustain
    /// segment. The `engine.pause()` right after hides it (a paused `AVAudioEngine` renders nothing), but it hides
    /// it the way a freeze-frame hides motion: the voices are still there, at full amplitude, the next time
    /// anything starts the graph. `playPreview` starts the graph for a single note, so the chord the user paused on
    /// came back with the preview — the reported symptom, "after playing, clicking a note mixes other sounds into
    /// the preview". `renderCountIn`'s "a note left ringing by the previous playback decays naturally" had the same
    /// hole under it: an un-released voice does not decay, so it sustained through the whole count-in.
    ///
    /// Measured on 2026-09-06 (`SwiftySynthPausedVoiceTests`, offline rendering, no hardware): five seconds of
    /// rendering after a pause still peaked at 0.024 against 0.111 while playing — 22%, flat, not a release tail.
    ///
    /// `cutPreviewNote` addresses one known channel; here nothing says which channels the sequencer left sounding,
    /// so it is all of them.
    private func silenceSoundingVoices() {
        for unit in attachedSynths {
            for channel in UInt8(0) ..< 16 {
                MIDISynthBuilder.sendControlChange(
                    into: unit, controller: 120, value: 0, onChannel: channel,
                )
            }
        }
    }

    /// Stop playback and rewind to the start. Different from
    /// `pause()` — the next `play` starts from the beginning (or
    /// from the supplied item).
    public func stop() {
        guard state != .exporting else { return }
        // Abandon a play that was waiting on the SoundFont load — the user stopped.
        pendingBackendPlay = nil
        if let backend {
            backend.stop()
        } else {
            sequencer?.stop()
            sequencer?.currentPositionInBeats = 0
            // The backend's own `stop()` already ends its voices; the AU path freezes them exactly as `pause()`
            // did — see `silenceSoundingVoices`.
            silenceSoundingVoices()
        }
        stopCursorTimer()
        if engine.isRunning {
            engine.pause()
        }
        state = .stopped
        currentCursor = nil
    }

    /// Drop the playback cursor. The host calls this when the user
    /// makes a fresh selection — MuseScore convention is that a new
    /// selection wins over the last cursor position, so the next
    /// play / space starts from the selection rather than where the
    /// cursor was parked. No-op while playing: the cursor timer is
    /// the source of truth then, and clearing under it would race
    /// the next tick.
    public func clearCursor() {
        guard state != .exporting else { return }
        guard state != .playing else { return }
        currentCursor = nil
    }

    /// Of the supplied items, the one with the smallest onset tick.
    /// Used by hosts to resolve a range selection's "first note"
    /// when starting playback. Returns `nil` when the timeline is
    /// not yet ready (no `prepare(score:)` call) or none of the
    /// items map into it.
    public func earliest(of items: [ScoreItemID]) -> ScoreItemID? {
        timeline?.earliest(of: items)
    }

    /// Rewrite the rendered SMF so it survives AUMIDISynth's quirks:
    ///
    /// 1. Strip `CC 121` (Reset All Controllers). MIDI 1.0 spec says
    ///    RAC must NOT reset RPN values (so Pitch Bend Sensitivity
    ///    is supposed to survive), but AUMIDISynth's implementation
    ///    appears to reset sensitivity to the GM ±2-semitone default
    ///    anyway. Combined with point 2 below, this means the SMF's
    ///    own RPN setup that follows the RAC can't get sensitivity
    ///    committed in time to be latched by the first noteOn voice.
    /// 2. Insert `CC 38 = 0` (Data Entry LSB) right after every
    ///    `CC 6` (Data Entry MSB). Data Entry is a 14-bit value
    ///    (`MSB << 7 | LSB`) and AUMIDISynth defers committing the
    ///    RPN update until both halves arrive.
    ///
    /// The renderer itself is left alone so SMF export keeps its
    /// MuseScore-equivalent byte stream — these compensations only
    /// apply to the bytes handed to `AVAudioSequencer`.
    ///
    /// The **tick-0 `programChange`** on `mixerManagedChannels` is
    /// **stripped** — same reasoning as CC 7 below. The renderer bakes
    /// each staff's initial GM program as a tick-0 program change on the
    /// staff's primary channel. Every backward seek across / behind
    /// tick 0 (the loop-wrap rewind in `tickCursor`, a seek-to-start)
    /// makes AVAudioSequencer chase and re-fire it on the render thread,
    /// clobbering a mixer-driven program override. Re-applying the mixer
    /// *after* `sequencer.start()` (what `play()` / `wrapToLoopStart()`
    /// do via `reapplyMixerPrograms()`) races that chase and loses on
    /// the wrap — exactly the failure CC 7 hit. Removing the tick-0
    /// program change for the channels the mixer owns makes
    /// `reapplyMixerPrograms()` the sole authority on their program
    /// (it re-asserts the mixer's value — the score's default when no
    /// override is set — after every start), so there is nothing left to
    /// chase. Only `tick == 0` is removed: any *later* program change on
    /// a primary channel (a mid-piece instrument switch) is kept and
    /// still fires.
    ///
    /// `programChange` on **non-managed** channels is left untouched.
    /// It's the only reliable way to program AUMIDISynth's per-channel
    /// state for the alternate channel flavours the renderer assigns
    /// (e.g. strings' arco / pizz), and those channels aren't mixer-
    /// owned, so no override can race them.
    ///
    /// `CC 7` (Channel Volume) on `mixerManagedChannels` is **stripped**.
    /// The renderer emits the score's baked-in CC 7 only at tick 0; every
    /// backward seek across / behind tick 0 (the loop-wrap rewind in
    /// `tickCursor`, the export sequencer's start) makes AVAudioSequencer
    /// chase and re-fire it on the render thread, clobbering the live
    /// mixer's volume / mute / solo. Re-applying the mixer *after*
    /// `sequencer.start()` races that chase and loses. Removing CC 7 for
    /// the channels the mixer owns (each staff's primary channel) makes
    /// `applyMixerState()` the sole authority on their volume — no race.
    /// Secondary playback-flavour channels (not mixer-managed) keep their
    /// CC 7 so the score's volume balance survives.
    nonisolated static func postProcessForMIDISynth(
        midi: inout MidiFile, mixerManagedChannels: Set<Int>,
    ) {
        // Lifted into shared SheetMusicMIDI so the Android engine gets identical behavior — the
        // Android SwiftySynth path was missing this and re-fired the SMF's CC 7 on first play.
        MidiSynthPostProcess.apply(midi: &midi, mixerManagedChannels: mixerManagedChannels)
    }

    /// MIDI channels whose volume / program the live mixer owns — every
    /// deduped (part × instrument) strip's live channel, not just each
    /// staff's primary. Passed to `MidiSynthPostProcess` so those
    /// channels' tick-0 program / CC 7 are stripped and the mixer stays
    /// the sole authority. Falls back to the staff-primary set before
    /// the first `prepare(score:)` builds a plan.
    private var mixerManagedChannels: Set<Int> {
        liveChannelPlan?.managedChannels ?? Set(staffMIDIChannels.values.map(Int.init))
    }

    /// `MidiRenderer.render(score:)` behind a one-entry cache keyed by score.
    /// Rendering every note is the expensive step; a count-in play re-assembles
    /// the SMF on every start, so caching the render keeps per-play cost at
    /// re-assembly + `sequencer.load`. Returns a value copy (`MidiFile` is a
    /// struct), so callers mutate freely without disturbing the cache.
    private func cachedRender(_ score: Score) throws -> MidiFile {
        if let cached = renderedMidiCache, cached.score == score {
            return cached.midi
        }
        var midi = try MidiRenderer.render(score: score)
        // Collapse the MuseScore-exact multi-port SMF onto the live
        // engine's single-port channel set BEFORE anything downstream
        // (sequencer load, `postProcessForMIDISynth`'s tick-0 stripping)
        // sees it — see `MidiChannelRemap`. `liveChannelPlan` is built
        // in `prepareSynth`, which always runs before this is first
        // called from a play / seek path; a `nil` plan (unprepared
        // engine) leaves the raw rendered channels untouched.
        if let liveChannelPlan {
            MidiChannelRemap.apply(midi: &midi, plan: liveChannelPlan)
        }
        renderedMidiCache = (score, midi)
        return midi
    }

    private func buildSequencer(for score: Score) throws {
        // Release the previous sequencer before creating its replacement — see the detailed note in
        // `buildCountInSequencer`. Two `AVAudioSequencer`s on one engine must never overlap, or the
        // old one's dealloc nulls the new one's engine sequence (every voice → sine seed tone). This
        // path is reachable with a live old sequencer via a forced rebuild after a count-in play
        // (`sequencerHasPreRoll`) — e.g. tap-to-seek during a count-in, or count-in toggled off.
        sequencer?.stop()
        sequencer = nil
        let sequencer = AVAudioSequencer(audioEngine: engine)
        // SheetMusicMIDI emits 1 track per staff (see
        // `MidiRenderer.render`). We append a metronome track to
        // the in-memory `MidiFile` *before* serializing — the
        // public `MidiRenderer.render` / `SheetMusic.exportMIDI`
        // path stays free of metronome events; only this playback
        // pipeline injects them.
        let midi = try PreRollSequenceAssembler.assembleNormal(
            rendered: cachedRender(score),
            metronomeBeats: metronomeBeats,
            mixerManagedChannels: mixerManagedChannels,
        )
        let bytes = try MidiWriter.write(midi)
        try sequencer.load(from: bytes, options: [])
        // Tracks are emitted one per flat staff in score order; route each
        // to its owning unit. The trailing metronome track is redirected by
        // `metronome.attach(to:)`, so skip indices >= staff count.
        let staffCount = staffIsDrum.count
        for (trackIdx, track) in sequencer.tracks.enumerated() {
            guard trackIdx < staffCount else { continue }
            track.destinationAudioUnit = synth(forStaff: trackIdx)
        }
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        // Assert pitch-bend sensitivity once the sequencer knows its
        // destination AU but before any play. This pairs with the
        // matching call in `play(...)` — the redundancy is defensive,
        // since which side wins the race against tick-0 SMF events
        // varies between fresh-build vs. cached-sequencer paths.
        if let melodicSynth {
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: melodicSynth, semitones: 12, onChannel: ch,
                )
            }
        }
        self.sequencer = sequencer
    }

    /// Build the count-in sequencer: the score's rendered content shifted past a
    /// metronome pre-roll region, a tempo seeded at sequencer tick 0, the
    /// toggle-gated body metronome (same shift), and a separate always-on
    /// pre-roll click track. `sequenceMap` (set by the caller) translates every
    /// later raw-position read/write back into score ticks.
    private func buildCountInSequencer(
        for score: Score, plan: CountInBeats.Result, baseTick: Int,
    ) throws {
        // Release the previous sequencer BEFORE creating its replacement. Two `AVAudioSequencer`s
        // bound to one `AVAudioEngine` must never coexist: the engine holds a single `MusicSequence`
        // slot, and `AVAudioSequencer.dealloc` unconditionally calls `engine.setMusicSequence(nil)`.
        // If the new sequencer has already claimed that slot at init, the *old* one's dealloc then
        // detaches the *new* sequence — Core Audio falls the orphaned sequence back onto its bank-less
        // default monotimbral synth, so every track (notes AND metronome clicks) degrades to the seed
        // sine tone on the second count-in play. Niling here deallocs the old sequencer while its own
        // sequence still owns the slot (a clean detach); `MetronomeController` holds its tracks weakly
        // so the dealloc is prompt. Same hazard, same fix in `buildSequencer`.
        sequencer?.stop()
        sequencer = nil
        let sequencer = AVAudioSequencer(audioEngine: engine)
        let assembled = try PreRollSequenceAssembler.assemble(
            rendered: cachedRender(score),
            metronomeBeats: metronomeBeats,
            mixerManagedChannels: mixerManagedChannels,
            plan: plan,
            baseTick: baseTick,
        )
        let bytes = try MidiWriter.write(assembled.midi)
        try sequencer.load(from: bytes, options: [])
        // Route each staff track to its owning synth. The two trailing tracks
        // (pre-roll click, then the body metronome as `.last`) are the
        // metronome's; skip them here.
        let staffCount = staffIsDrum.count
        for (trackIdx, track) in sequencer.tracks.enumerated() {
            guard trackIdx < staffCount else { continue }
            track.destinationAudioUnit = synth(forStaff: trackIdx)
        }
        // Route the body metronome (`.last`, toggle-gated) exactly as normal,
        // then the always-on pre-roll click track.
        metronome.attach(to: sequencer)
        if assembled.preRollTrackIndex < sequencer.tracks.count {
            metronome.attachPreRoll(
                track: sequencer.tracks[assembled.preRollTrackIndex],
            )
        }
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        if let melodicSynth {
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: melodicSynth, semitones: 12, onChannel: ch,
                )
            }
        }
        self.sequencer = sequencer
    }

    /// Pure core of `tickCursor`'s "raw sequencer tick → cursor" mapping,
    /// factored (and `static`) so it is unit-testable without a live sequencer
    /// or audio graph. Returns `nil` while inside the count-in pre-roll — the
    /// signal for `tickCursor` to keep `currentCursor` pinned at the start —
    /// and the frame cursor at the mapped score tick otherwise. `nonisolated`
    /// (it touches no actor state) so it is callable from a synchronous test.
    nonisolated static func mappedCursor(
        rawSequencerTick: Int, sequenceMap: SequenceMap, timeline: PlaybackTimeline,
        unroll: PlaybackUnroll = .identity,
    ) -> ScoreCursor? {
        guard let scoreTick = sequenceMap.scoreTick(fromSequencer: rawSequencerTick)
        else { return nil }
        return timeline.frame(
            atTick: unroll.notatedTick(fromUnrolled: scoreTick),
        )?.cursor
    }

    /// The cursor a `play(from:)` should actually anchor at, resolving the nil-cursor convention the
    /// same way `positionForNormalPlay` does: an explicit `cursor` always wins; a nil cursor means
    /// "resume from the current position" while playing/paused, and "from the top" (nil) only when
    /// stopped. Extracted (and `nonisolated`) so the resume-vs-restart choice is unit-testable without
    /// an audio graph — the count-in rebuild depends on it to avoid restarting at m1 on resume.
    nonisolated static func effectiveStartCursor(
        cursor: ScoreCursor?, isStopped: Bool, currentCursor: ScoreCursor?,
    ) -> ScoreCursor? {
        cursor ?? (isStopped ? nil : currentCursor)
    }

    private func startCursorTimer() {
        stopCursorTimer()
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            repeats: true,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tickCursor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func stopCursorTimer() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    /// Internal rather than private so tests can drive a single poll deterministically instead
    /// of waiting on the 30 Hz timer (same reason `wrapToLoopStart` is internal).
    func tickCursor() {
        guard let timeline else { return }
        if let backend {
            backendTickCursor(backend: backend, timeline: timeline)
            return
        }
        guard let sequencer else { return }
        // Drive the cursor off `currentPositionInBeats`, not
        // `currentPositionInSeconds`. AVAudioSequencer derives
        // `…InSeconds` from `…InBeats` using the sequencer's *current*
        // tempo (not the integrated tempo map), so on a score with
        // tempo changes the seconds value can race ahead of real
        // playback. Beats are the stable monotonic clock — convert to
        // ticks via the score's division and look up by tick.
        let beats = sequencer.currentPositionInBeats
        if !sequencer.isPlaying {
            stopCursorTimer()
            state = .stopped
            return
        }
        // `currentPositionInBeats` can read back non-finite (NaN / ±∞) or wildly
        // out of range while the sequencer is between halt/restart transitions
        // (seek, loop-wrap, or an audio-session interruption tearing the render
        // graph down under a still-"playing" sequencer). `Int(_:)` traps on such
        // a value (EXC_BREAKPOINT — surfaced in Crashlytics as
        // `PlaybackEngine.tickCursor()`); `Int(exactly:)` returns nil instead, so
        // we skip this poll tick and self-heal on the next one.
        guard let rawSeqTick = Int(exactly: (beats * Double(timeline.division)).rounded())
        else { return }
        // Translate the raw sequencer tick into a score tick. `nil` means we're
        // still inside the count-in pre-roll — keep `currentCursor` pinned at
        // the start position (set at play time) and take no action until real
        // playback crosses into the shifted score content.
        guard let tick = sequenceMap.scoreTick(fromSequencer: rawSeqTick) else {
            return
        }
        // Manual loop wrap. See `loopRange`'s doc comment for why we
        // can't lean on `AVMusicTrack.loopRange`: it wraps per-track
        // playheads sample-accurately but leaves the SMF master tempo
        // track playing through monotonically, so mid-loop `.tempo` /
        // `.timeSignature` meta events fire on iteration 1 only and
        // never re-fire. Seeking via `currentPositionInBeats` here
        // reruns AVAudioSequencer's tempo-track event scan up to the
        // new position, restoring the tempo trajectory for every
        // iteration.
        // `tick` is UNROLLED, so the bound it is measured against has to be too.
        if let loop = transportLoop, tick >= loop.endTick {
            wrapToLoopStart(loop)
            return
        }
        // The polled tick is UNROLLED (the SMF's coordinates);
        // translate to the notated tick before the frame lookup so
        // the cursor tracks repeats' later passes and jump targets.
        if let frame = timeline.frame(atTick: unroll.notatedTick(fromUnrolled: tick)) {
            if frame.cursor != currentCursor {
                currentCursor = frame.cursor
            }
        }
        // End-of-score detection compares against the UNROLLED length
        // (falling back to the notated length for an identity map).
        // Skip while looping — the wrap branch above handles the
        // boundary, and a stale read here mustn't fire `stop()`.
        if loopRange == nil,
           tick >= max(unroll.totalUnrolledTicks, timeline.totalTicks)
        {
            stop()
        }
    }

    /// Injected-backend cursor poll: the backend's tick already lives in
    /// score-tick space (normal play uses the un-shifted assembled SMF), so no
    /// `SequenceMap` translation is needed. Same loop-wrap / end-stop decisions
    /// as the AUMIDISynth `tickCursor`.
    /// Fold a NOTATED time into the active A-B loop region — the seconds counterpart of
    /// `foldTickForLoop`, for readers whose clock is time-based. Pass-through with no loop.
    private func foldSecondsForLoop(_ seconds: TimeInterval) -> TimeInterval {
        guard let loop = loopRange, let timeline else { return seconds }
        let start = timeline.seconds(atTick: Double(loop.startTick))
        let end = timeline.seconds(atTick: Double(loop.endTick))
        guard end > start, seconds >= end else { return seconds }
        return start + (seconds - start).truncatingRemainder(dividingBy: end - start)
    }

    /// The backend transport's position expressed in NOTATED timeline seconds, loop-folded —
    /// what every host-facing elapsed-time reader wants. During a count-in the score transport
    /// is parked at the start position, so this reports that position and a scrubber sits still
    /// rather than jumping.
    private func backendNotatedSeconds(
        _ backend: any SynthBackend, timeline _: PlaybackTimeline,
    ) -> TimeInterval {
        foldSecondsForLoop(
            unrolledTimeMap.notatedSeconds(fromUnrolled: backend.currentPositionSeconds),
        )
    }

    private func backendTickCursor(
        backend: any SynthBackend, timeline: PlaybackTimeline,
    ) {
        // Work in score-space SECONDS, not in a polled tick. `backend.currentTick` is a
        // `frame(atTime:)` lookup, and `frames` carries note ONSETS only while
        // `frame(atTime:)` clamps to the last one — so the tick saturates at the final
        // onset. Both boundaries below sit strictly past it (`itemEndTicks` and
        // `totalTicks` are offsets), which is why comparing against the tick never fired:
        // playback stayed `.playing` with the cursor parked on the last note, and a
        // whole-score repeat never wrapped.
        // During a count-in this is the held start position, so the cursor stays pinned there
        // and neither branch below can fire early: the transport hasn't moved yet.
        let scoreSeconds = backend.currentPositionSeconds
        // The transport's clock is the UNROLLED sequence's, so the loop's end has to be expressed
        // there too — `TransportLoop.endSeconds`. Comparing against the NOTATED end time wrapped
        // early by exactly the head start the unrolled sequence has accumulated, which on a score
        // with a repeat meant the region was cut short and, after the seek below, replayed from
        // somewhere else entirely.
        if let loop = transportLoop, let notatedLoop = loopRange,
           scoreSeconds >= loop.endSeconds
        {
            // The count is over once the first pass is: swap the count-in metronome sequence for
            // the plain one so the wrapped pass clicks from the loop's start (that sequence keeps
            // only the beats from the count-in's start position onward, offset to sit behind the
            // pre-roll — a wrap to an earlier tick has nothing there to play).
            if backendMetronomeHasPreRoll, let score = sequencerScore,
               let rendered = try? cachedRender(score)
            {
                loadBackendMetronomeSequence(backend: backend, rendered: rendered)
                backend.setMetronomeMuted(!metronome.isEnabled)
            }
            // `seek(toTick:)` and `frame(atTick:)` both speak NOTATED ticks — the backend maps its
            // argument onto the unrolled clock itself (`setUnrolledTimeMap`).
            backend.seek(toTick: notatedLoop.startTick)
            reapplyMixerPrograms()
            applyMixerState()
            currentCursor = timeline.frame(atTick: notatedLoop.startTick)?.cursor
            return
        }
        // Project the transport's UNROLLED seconds onto the notated timeline before the frame
        // lookup — the seconds-space counterpart of the AUMIDISynth path's
        // `unroll.notatedTick(fromUnrolled:)`. Without it, a score with a repeat runs the
        // cursor a full measure-play ahead from the second pass on, then saturates on the last
        // frame once the unrolled position passes the notated duration.
        let notatedSeconds = unrolledTimeMap.notatedSeconds(fromUnrolled: scoreSeconds)
        if let frame = timeline.frame(atTime: notatedSeconds), frame.cursor != currentCursor {
            currentCursor = frame.cursor
        }
        // End of score: ask the TRANSPORT, not the timeline. The loaded SMF is the
        // unrolled render (repeats / jumps expanded) and may carry a count-in shift on
        // top, while the timeline is notated and un-shifted — so any timeline-space end
        // comparison is wrong on exactly the scores that have repeats. `isAtEnd` answers
        // in the SMF's own coordinates and needs no reconstruction. (The AUMIDISynth path
        // gets the same guarantee from its `!sequencer.isPlaying` check.)
        if loopRange == nil, backend.isAtEnd {
            stop()
        }
    }

    /// Seek the playhead back to the loop's start and resume. Driven by
    /// `tickCursor` when the polled position reaches the loop end. Takes the loop already
    /// projected onto the transport — the sequencer plays the unrolled render, so the notated
    /// start tick is not where that music sits.
    func wrapToLoopStart(_ loop: TransportLoop) {
        guard let sequencer, let timeline else { return }
        // Seek back in *sequencer* ticks: with a count-in pre-roll the loop
        // start (a score tick) sits at `preRollTicks + (startTick - baseTick)`.
        // Because all score content — including the loop — lives at seq tick
        // >= preRollTicks, the wrap never re-enters the pre-roll, so the
        // count-in fires once and loops replay only the body.
        let startBeats =
            Double(sequenceMap.sequencerTick(fromScore: loop.startTick))
            / Double(timeline.division)
        sequencer.currentPositionInBeats = startBeats
        // Writing `currentPositionInBeats` while the sequencer is
        // playing halts it — restart immediately so audio keeps
        // flowing. start() on an already-running sequencer is a
        // no-op, but Apple's setter halts before the assignment
        // returns, so we must always re-start here.
        try? sequencer.start()
        // Re-assert the mixer's program / volume / mute / solo for this
        // loop iteration. Both the tick-0 programChange and CC 7 on
        // mixer-managed channels are stripped from the SMF in
        // `postProcessForMIDISynth`, so the backward seek's controller
        // chase has nothing to re-fire on those channels — these calls
        // are now the *sole* authority for the wrapped iteration (not a
        // race against the chase). `reapplyMixerPrograms()` re-selects
        // the staff program (the user's override, or the score default
        // when none); `applyMixerState()` re-applies volume / mute /
        // solo.
        reapplyMixerPrograms()
        applyMixerState()
        if let frame = timeline.frame(atTick: loop.startTick) {
            currentCursor = frame.cursor
        }
    }

    /// Stop the engine and release samplers. Safe to call multiple
    /// times; subsequent `prepare(score:)` calls will spin it back up.
    /// Quiesce the render IO thread before this instance — and the
    /// `AVAudioUnit` nodes it owns — are deallocated. A `PlaybackEngine`
    /// dropped while its engine is still running would otherwise tear the
    /// nodes down out from under a live render cycle and fault on the IO
    /// thread (`EXC_BAD_ACCESS` in `AudioUnitRender`), the same race
    /// `teardown()` guards against. `teardown()` is `@MainActor`-isolated
    /// and so unreachable from a `nonisolated deinit`; `isolated deinit`
    /// would need macOS 15 / iOS 18 (this package deploys to macOS 14 /
    /// iOS 17). `engine.stop()` alone tears the IO thread down
    /// synchronously, which is all that's required for a safe
    /// teardown-on-dealloc, and is a no-op on an already-stopped engine —
    /// so an explicit `teardown()` first leaves this harmless.
    deinit {
        // Neither notification observer needs unregistering here — each `NotificationObserverToken` removes its own
        // in its (unisolated) deinit as this instance releases it.
        engine.stop()
    }

    public func teardown() {
        // A rebuild scheduled by an audio configuration change must not run against a graph the host has just torn
        // down. `performConfigurationChangeRestart()` would also refuse (teardown leaves `state == .stopped`), but
        // cancelling here is what makes that a belt-and-braces guard rather than the only one.
        pendingConfigurationRestart?.cancel()
        pendingConfigurationRestart = nil
        stop()
        clearLoop()
        // Quiesce the render thread BEFORE mutating the graph. `stop()` above
        // only *pauses* the engine (it calls `engine.pause()`), which leaves
        // AURemoteIO's IO thread and the output unit's render-notify block
        // live. Freeing the `AVAudioSequencer` (its `dealloc` detaches the
        // music sequence from the engine, mutating live sequencing state) or
        // detaching / disconnecting the synth or the metronome sampler out from
        // under a paused-but-not-stopped engine races the in-flight render cycle
        // and faults on the IO thread — observed in Crashlytics as
        // EXC_BAD_ACCESS in `_Block_copy` (render-notify) and in `ProcessMono` /
        // `SamplerNote::Render` (MIDISynth voice render). A full `engine.stop()`
        // tears the IO thread down synchronously, so the graph edits below run
        // with no renderer active. This MUST precede `sequencer = nil`: the
        // previous ordering freed the sequencer first and left ~118 users
        // crashing in the render-notify `_Block_copy` on 1.7.0.
        //
        // `engine.stop()` is unconditional: `pause()` already cleared
        // `isRunning`, so the previous `if engine.isRunning` guard skipped the
        // hard stop entirely and left the graph being mutated under a live
        // render unit. `stop()` is a safe no-op on an already-stopped engine.
        engine.stop()
        sequencer = nil
        sequencerScore = nil
        if let backend {
            backend.teardown()
            // Teardown supersedes any in-flight SoundFont load; clear the
            // "preparing" flag so it can't stay stuck true after release.
            isPreparingSoundfont = false
            if backend.outputNode.engine != nil {
                engine.disconnectNodeOutput(backend.outputNode)
                engine.detach(backend.outputNode)
            }
        }
        for old in attachedSynths {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        melodicSynth = nil
        percussionSynth = nil
        staffMIDIChannels.removeAll()
        staffIsDrum.removeAll()
        liveChannelPlan = nil
        instrumentMIDIChannels.removeAll()
        staffChannelSwitches.removeAll()
        metronome.teardown()
        // The engine no longer holds any audio, so the exclusive claim a `.mixUntilPlay` host escalated to is spent:
        // a later `prepare(score:)` on this same instance is a fresh score load and starts out mixing again. Hosts
        // typically deactivate the session around here too, which is theirs to do — the engine only forgets that it
        // escalated.
        hasEscalatedAudioSession = false
        needsAudioSessionReactivation = false
    }
}
