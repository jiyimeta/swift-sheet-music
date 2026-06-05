// swiftlint:disable file_length
@preconcurrency import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

/// Audio playback for `Score`s, backed by `AVAudioEngine` and a
/// single multi-timbral `AVAudioUnitMIDIInstrument` (AUMIDISynth).
///
/// Every staff in `prepare(score:)` is addressed by the MIDI channel
/// the renderer assigns it (`MidiRenderer.staffChannels(score:)`).
/// The full General MIDI SoundFont returned by `SoundfontResolver`
/// is loaded once into the shared synth, and every (channel, program)
/// combination is pre-loaded into the AU's preset cache so runtime
/// program changes from the mixer hit the cache instead of triggering
/// an unreliable on-demand SF2 read.
///
/// AUMIDISynth (`kAudioUnitSubType_MIDISynth`) is used in preference
/// to `AVAudioUnitSampler` because AUSampler ignores RPN 0,0 (Pitch
/// Bend Sensitivity) — its bend range is hard-coded to ±2 semitones,
/// which audibly truncates portamento glissandi we render at ±12.
/// See `MIDISynthBuilder` for the wrapper that builds and configures
/// the instrument.
@MainActor
@Observable
public final class PlaybackEngine { // swiftlint:disable:this type_body_length
    private let resolver: SoundfontResolver
    /// Resolves the metronome's click sound (host WAVs → SF2, host SF2,
    /// or the GM drum-kit fallback). See `MetronomeClickResolver`.
    private let clickResolver: MetronomeClickResolver
    /// `internal` so `PlaybackEngine+Master` can call
    /// `engine.attach` / `engine.connect` from a sibling file when
    /// building the master output stage.
    let engine = AVAudioEngine()
    /// The shared multi-timbral AUMIDISynth. Rebuilt on every
    /// `prepare(score:)`. `internal` so the mixer / export extensions
    /// in sibling files can read it directly.
    var synth: AVAudioUnitMIDIInstrument?
    /// Renderer-assigned MIDI channel per flat staff index. Used to
    /// address each staff's notes / mixer state on the shared synth.
    private var staffMIDIChannels: [Int: UInt8] = [:]
    /// Drum-staff flag per flat staff index, cached so the mixer can
    /// decide whether to expose a GM-program picker (drum-kit parts
    /// hide it because the program slot is ignored on MIDI channel 9).
    private var staffIsDrum: [Int: Bool] = [:]

    /// Master output stage. The score synth feeds `scoreGainMixer`,
    /// whose `outputVolume` is the user's master gain (`0...3`). Its
    /// output is summed with the metronome at `sumMixer`, brick-walled
    /// by `limiter`, then routed into `mainMixerNode`. Built once in
    /// `init` and reused across every `prepare(score:)`, so `masterGain`
    /// survives score reloads. `internal` so the `+Master` / `+Export`
    /// extensions in sibling files can reach the nodes directly.
    let scoreGainMixer = AVAudioMixerNode()
    let sumMixer = AVAudioMixerNode()
    let limiter = PlaybackEngine.makePeakLimiter()

    /// Linear amplitude multiplier applied to the full mix, post
    /// per-channel mixing. `1.0` = unity. Clamped to `0...3` by
    /// `setMasterGain`. Setter is module-internal so the `+Master`
    /// extension (a different file) can mirror the clamped value here.
    public internal(set) var masterGain: Float = 1.0 // swiftlint:disable:this inclusive_language

    /// Current A4-calibration offset in cents (0 = A4 440 Hz). Stored so it survives
    /// synth rebuilds in `prepareSynth`, like `masterGain`.
    public private(set) var masterTuningCents: Double = 0 // swiftlint:disable:this inclusive_language

    /// Used to silence pending preview note-offs when the engine is
    /// torn down or a new score is prepared.
    private let previewQueue = DispatchQueue(
        label: "swift-sheet-music.playback.preview",
        qos: .userInteractive,
    )
    /// Preview notes currently sounding (note-off pending). Lets the
    /// drain logic re-pause the audio graph only once the *last*
    /// overlapping preview has ended. Main-actor isolated.
    private var activePreviewCount = 0
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
    /// Most recent rate set by the host. Stored separately from the
    /// sequencer so the value survives `buildSequencer` rebuilds —
    /// every fresh `AVAudioSequencer` starts at 1.0 and we re-apply
    /// this value once it's built.
    private var pendingRate: Float = 1.0
    /// Pre-computed time → item mapping, used by the cursor poll
    /// to translate `sequencer.currentPositionInSeconds` into a
    /// `ScoreItemID`.
    private var timeline: PlaybackTimeline?
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

    public init(
        soundfontResolver: SoundfontResolver,
        metronomeClickProvider: MetronomeClickProvider? = nil,
    ) {
        resolver = soundfontResolver
        clickResolver = MetronomeClickResolver(
            provider: metronomeClickProvider,
            soundfontResolver: soundfontResolver,
        )
        // The metronome joins the master stage at `sumMixer` (post-gain,
        // pre-limiter) so it is limited along with the boosted score but
        // is not itself boosted by the master gain.
        metronome = MetronomeController(engine: engine, output: sumMixer)
        buildMasterChain()
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
    }

    /// Retune playback to an A4 reference expressed as a cents offset from 440 Hz
    /// (e.g. 432 Hz ≈ -31.77¢). AUMIDISynth ignores MIDI master-tuning RPNs but
    /// honors its global AudioUnit Coarse/Fine Tuning params, which we set here —
    /// covering every channel with zero latency. Persists across `prepare`.
    public func setMasterTuning(cents: Double) { // swiftlint:disable:this inclusive_language
        guard state != .exporting else { return }
        masterTuningCents = cents
        guard let synth else { return }
        Self.applyMasterTuning(to: synth, cents: cents)
    }

    /// AUMIDISynth global-scope AudioUnit tuning parameter ids (from its
    /// `kAudioUnitProperty_ParameterList`): 901 = Coarse Tuning (semitones),
    /// 902 = Fine Tuning (cents).
    private static let coarseTuningParameterID: AudioUnitParameterID = 901
    private static let fineTuningParameterID: AudioUnitParameterID = 902

    private static func applyMasterTuning( // swiftlint:disable:this inclusive_language
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
        /// Resolved metronome SoundFont URL (host click SF2, host SF2, or
        /// GM drum-kit), so the export plays the same click as live.
        let metronomeSoundFontURL: URL?
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
            metronomeSoundFontURL: clickResolver.resolvedSoundFontURL(),
        )
    }

    // MARK: Internal accessors for `PlaybackEngine+Mixer`

    func midiChannel(forStaff idx: Int) -> UInt8? {
        staffMIDIChannels[idx]
    }

    func isDrumStaff(_ idx: Int) -> Bool {
        staffIsDrum[idx] ?? false
    }

    /// Re-send program-change on each staff's primary channel using
    /// the program the mixer currently advertises. Called right after
    /// `sequencer.start()` so the SMF's tick-0 programChange events
    /// have already fired and our re-apply wins the race; also called
    /// after the user changes a program from the picker while the
    /// engine was paused, since the queued event from that picker
    /// click can lose to the SMF on resume.
    func reapplyMixerPrograms() {
        guard let synth else { return }
        for channel in mixerChannels {
            guard case let .staff(idx) = channel.id,
                  let program = channel.program,
                  let midiCh = staffMIDIChannels[idx],
                  midiCh != 9
            else { continue }
            // Same dance as `loadProgram`: preload to populate the
            // channel's preset slot, then plain PC to select it.
            MIDISynthBuilder.preloadPreset(
                into: synth,
                bankMSB: 0, bankLSB: 0, program: program,
                onChannel: midiCh,
            )
            let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
            _ = MusicDeviceMIDIEvent(
                synth.audioUnit, pcStatus, UInt32(program), 0, 0,
            )
        }
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        metronome.isEnabled = enabled
    }

    func setMetronomeVolume(_ volume: Float) {
        metronome.volume = volume
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
        guard let synth,
              let midiCh = staffMIDIChannels[idx],
              midiCh != 9
        else { return }
        MIDISynthBuilder.preloadPreset(
            into: synth,
            bankMSB: 0, bankLSB: 0, program: program,
            onChannel: midiCh,
        )
        let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
        _ = MusicDeviceMIDIEvent(
            synth.audioUnit, pcStatus, UInt32(program), 0, 0,
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
        // Stop any in-flight playback before tearing down samplers.
        stop()
        // Loop ticks are resolved against the previous timeline; clear
        // them so a stale region from the prior score can't fire on
        // the new one.
        clearLoop()
        sequencer = nil
        sequencerScore = nil
        timeline = PlaybackTimeline(score: score)
        metronomeBeats = PlaybackTimeline.metronomeBeats(score: score)
        // Resolve the metronome's SoundFont through the click provider:
        // `.clickSamples` builds an SF2 from the host's WAVs, `.soundFont`
        // uses a host SF2, and `.defaultGM` (or no provider) falls back to
        // the GM drum-kit (notes 76 / 77). AUMIDISynth loads it unchanged.
        metronome.prepare(soundfontURL: clickResolver.resolvedSoundFontURL())
        // Tear down the synth from a previous score, if any.
        if let oldSynth = synth {
            engine.disconnectNodeOutput(oldSynth)
            engine.detach(oldSynth)
            synth = nil
        }
        staffMIDIChannels.removeAll()
        staffIsDrum.removeAll()

        #if os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            // Request a concrete hardware sample rate before activating.
            // iOS's audio HAL can get its system-wide I/O rate stuck at an
            // odd value (e.g. 24 kHz left over from another app's Bluetooth
            // HFP call), and a session that simply adopts whatever rate the
            // system hands back then renders the whole graph against that
            // stale clock — heard as playback that is both sped up and
            // pitched up, and which survives an app relaunch because the
            // wedge lives in the system audio daemon, not our process.
            // Asking for a definite rate makes `setActive` reconfigure the
            // HAL toward it, which un-sticks that state without a reboot.
            // 48 kHz is the native rate of modern iOS output hardware, so on
            // a healthy device this is a no-op (no forced resample); it only
            // takes effect when the system was parked somewhere unexpected.
            // Best-effort: the route may clamp or ignore it (the graph still
            // adapts because every `connect` uses `format: nil`), so a
            // failure here must not abort score preparation.
            try? session.setPreferredSampleRate(48000)
            try session.setActive(true, options: [])
        #endif

        try prepareSynth(score: score)

        rebuildMixerChannels(for: score)
        applyMixerState()

        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Build the shared multi-timbral AUMIDISynth, load the full GM
    /// SoundFont once, pre-cache every (channel, program) preset, and
    /// configure per-channel pitch-bend sensitivity to match the
    /// renderer's ±12-semitone portamento output.
    private func prepareSynth(score: Score) throws {
        let url = resolver.defaultGMSoundfontURL
        let channels = MidiRenderer.staffChannels(score: score)

        let instrument = MIDISynthBuilder.make()
        engine.attach(instrument)
        engine.connect(
            instrument, to: scoreGainMixer, format: nil,
        )
        if let url {
            // Load the SF2 with (0, 0) as the seed preset so the file
            // is parsed and resident in the AU. Per-channel presets
            // load on-demand at sequencer start (via the SMF's tick-0
            // programChange events, which go through the render thread
            // and trigger AUMIDISynth's load machinery reliably) and
            // again whenever the user picks a new program (via
            // `loadProgram` → `preloadPreset`).
            try? MIDISynthBuilder.loadSoundFont(
                into: instrument, url: url,
                bankMSB: 0, bankLSB: 0, program: 0,
            )
        }
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: instrument, semitones: 12, onChannel: ch,
            )
        }
        synth = instrument
        Self.applyMasterTuning(to: instrument, cents: masterTuningCents)

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
    public func playPreview(
        noteID: NoteID,
        in score: Score,
        duration: TimeInterval = 0.3,
        velocity: UInt8 = 96,
    ) {
        guard state != .exporting else { return }
        guard let pitch = pitch(for: noteID, in: score) else { return }
        let flatIdx = score.allStaves.firstIndex(where: {
            $0.address == noteID.staff
        }) ?? -1
        guard let instrument = synth,
              let midiChannel = staffMIDIChannels[flatIdx]
        else { return }
        // A paused `AVAudioEngine` renders nothing, so a preview note would be
        // silent when the host parks the graph between plays (e.g. to keep
        // Control Center from showing active audio before the user hits play).
        // Resume the graph for the preview; the drain below restores the paused
        // state once the last overlapping preview ends.
        if !engine.isRunning {
            try? engine.start()
            if state != .playing {
                previewShouldRepauseEngineOnDrain = true
            }
        }
        activePreviewCount += 1
        instrument.startNote(
            pitch, withVelocity: velocity, onChannel: midiChannel,
        )
        previewQueue.asyncAfter(
            deadline: .now() + duration,
        ) { [weak self, weak instrument] in
            instrument?.stopNote(pitch, onChannel: midiChannel)
            Task { @MainActor [weak self] in
                guard let self else { return }
                activePreviewCount -= 1
                guard activePreviewCount == 0,
                      previewShouldRepauseEngineOnDrain
                else { return }
                previewShouldRepauseEngineOnDrain = false
                // Don't pause a graph that real playback is now driving.
                if state != .playing, engine.isRunning {
                    engine.pause()
                }
            }
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

    // MARK: - Full playback

    /// Begin playing the score from `from` (or from the start when
    /// `from == nil`). The first call lazily builds the sequencer
    /// from the score's MIDI rendering and routes each track to
    /// its matching staff sampler. Subsequent calls just rewind /
    /// re-position the existing sequencer, which keeps re-press of
    /// Space / the play button cheap.
    public func play(from cursor: ScoreCursor? = nil, in score: Score) {
        guard state != .exporting else { return }
        guard let timeline else { return }
        do {
            if sequencer == nil || sequencerScore != score {
                try buildSequencer(for: score)
                sequencerScore = score
            }
            guard let sequencer else { return }
            // Resume the audio graph if a previous `pause()` paused it.
            // `AVAudioEngine.start()` is the documented resume path after
            // `pause()`; safe no-op if already running.
            if !engine.isRunning {
                try engine.start()
            }
            // Position by beats. `currentPositionInSeconds` is derived
            // from beats using the player's current tempo (not the
            // tempo map), so seeking via seconds on a tempo-curved
            // score lands at the wrong tick. Beats / ticks bypass that.
            //
            // `targetTick == nil` means "resume from the paused
            // position" — leave the sequencer's beat alone unless a
            // loop snap forces a move.
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
                sequencer.currentPositionInBeats =
                    Double(t) / Double(timeline.division)
                currentCursor = timeline.frame(atTick: t)?.cursor
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
            if let synth {
                for ch: UInt8 in 0 ..< 16 where ch != 9 {
                    MIDISynthBuilder.setPitchBendSensitivity(
                        into: synth, semitones: 12, onChannel: ch,
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

    /// Reposition the playback cursor without changing play / pause
    /// state. Used for click-to-seek during playback — the user taps
    /// a note and audio jumps to that note while continuing to play.
    /// No-op when there is no sequencer yet (call `prepare(score:)`
    /// first) or when `cursor` doesn't resolve into the timeline.
    public func seek(to cursor: ScoreCursor) {
        guard state != .exporting else { return }
        guard let timeline, let sequencer,
              let frame = timeline.frame(forCursor: cursor)
        else {
            return
        }
        let tick = snapTickToLoop(frame.tick)
        sequencer.currentPositionInBeats =
            Double(tick) / Double(timeline.division)
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
    }

    private func apply(loop: LoopRange) {
        loopRange = loop
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
    public var currentTimeSeconds: TimeInterval {
        guard let timeline, let sequencer else { return 0 }
        let rawTick = Int(
            (sequencer.currentPositionInBeats * Double(timeline.division))
                .rounded(),
        )
        let tick: Int
        if let loop = loopRange, rawTick >= loop.endTick {
            let len = loop.endTick - loop.startTick
            tick = loop.startTick + (rawTick - loop.startTick) % len
        } else {
            tick = rawTick
        }
        return timeline.frame(atTick: tick)?.timeSeconds ?? 0
    }

    /// Total playable duration in seconds for the loaded score.
    /// Zero before `prepare(score:)` runs.
    public var totalTimeSeconds: TimeInterval {
        timeline?.totalSeconds ?? 0
    }

    /// Skip playback forward (`seconds > 0`) or backward
    /// (`seconds < 0`) relative to the current position, clamped to
    /// `[0, totalTimeSeconds]`. Preserves play / pause state — when
    /// playing, restarts the sequencer at the new position so audio
    /// keeps flowing; when paused, just moves the cursor and the next
    /// `play()` resumes from there. No-op when no sequencer is built.
    public func skip(by seconds: TimeInterval) {
        guard state != .exporting else { return }
        guard let timeline, let sequencer else { return }
        let now = currentTimeSeconds
        let target = max(0, min(timeline.totalSeconds, now + seconds))
        guard let frame = timeline.frame(atTime: target) else { return }
        if state == .playing, let score = sequencerScore {
            // Mirror `play(from:in:)` semantics — writing
            // `currentPositionInBeats` while the sequencer is running
            // halts it and freezes the cursor timer on its next tick.
            play(from: frame.cursor, in: score)
        } else {
            let tick = snapTickToLoop(frame.tick)
            sequencer.currentPositionInBeats =
                Double(tick) / Double(timeline.division)
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
        sequencer?.stop()
        stopCursorTimer()
        if engine.isRunning {
            engine.pause()
        }
        state = .paused
    }

    /// Stop playback and rewind to the start. Different from
    /// `pause()` — the next `play` starts from the beginning (or
    /// from the supplied item).
    public func stop() {
        guard state != .exporting else { return }
        sequencer?.stop()
        sequencer?.currentPositionInBeats = 0
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
    /// `programChange` is intentionally *kept* in the SMF. Empirically
    /// that's the only reliable way to program AUMIDISynth's
    /// per-channel state for the alternate channel flavours the
    /// renderer assigns (e.g. strings' arco / pizz). Tradeoff: the
    /// SMF re-fires those tick-0 program changes on every play /
    /// seek-to-start, clobbering mixer-driven program overrides —
    /// `play()` re-applies the mixer state after `sequencer.start()`
    /// to win the race deterministically.
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
        for trackIdx in midi.tracks.indices {
            var out: [TimedMidiEvent] = []
            out.reserveCapacity(midi.tracks[trackIdx].events.count + 8)
            for event in midi.tracks[trackIdx].events {
                if case let .controlChange(_, controller, _) = event.event,
                   controller == 121
                {
                    continue
                }
                if case let .controlChange(channel, controller, _)
                    = event.event, controller == 7,
                    mixerManagedChannels.contains(channel)
                {
                    continue
                }
                out.append(event)
                if case let .controlChange(channel, controller, _)
                    = event.event, controller == 6
                {
                    out.append(TimedMidiEvent(
                        tick: event.tick,
                        event: .controlChange(
                            channel: channel, controller: 38, value: 0,
                        ),
                    ))
                }
            }
            midi.tracks[trackIdx] = MidiTrack(events: out)
        }
    }

    private func buildSequencer(for score: Score) throws {
        let sequencer = AVAudioSequencer(audioEngine: engine)
        // SheetMusicMIDI emits 1 track per staff (see
        // `MidiRenderer.render`). We append a metronome track to
        // the in-memory `MidiFile` *before* serializing — the
        // public `MidiRenderer.render` / `SheetMusic.exportMIDI`
        // path stays free of metronome events; only this playback
        // pipeline injects them.
        var midi = try MidiRenderer.render(score: score)
        midi.tracks.append(metronome.metronomeTrack(
            beats: metronomeBeats, division: midi.division,
        ))
        Self.postProcessForMIDISynth(
            midi: &midi,
            mixerManagedChannels: Set(staffMIDIChannels.values.map(Int.init)),
        )
        let bytes = try MidiWriter.write(midi)
        try sequencer.load(from: bytes, options: [])
        // Every staff track routes to the shared multi-timbral synth;
        // the renderer's per-track channel byte does the dispatch. The
        // metronome track (appended last) is picked up by
        // `metronome.attach(to:)` below.
        for track in sequencer.tracks {
            if let synth {
                track.destinationAudioUnit = synth
            }
        }
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        // Assert pitch-bend sensitivity once the sequencer knows its
        // destination AU but before any play. This pairs with the
        // matching call in `play(...)` — the redundancy is defensive,
        // since which side wins the race against tick-0 SMF events
        // varies between fresh-build vs. cached-sequencer paths.
        if let synth {
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: synth, semitones: 12, onChannel: ch,
                )
            }
        }
        self.sequencer = sequencer
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

    private func tickCursor() {
        guard let sequencer, let timeline else { return }
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
        let rawTick = Int((beats * Double(timeline.division)).rounded())
        // Manual loop wrap. See `loopRange`'s doc comment for why we
        // can't lean on `AVMusicTrack.loopRange`: it wraps per-track
        // playheads sample-accurately but leaves the SMF master tempo
        // track playing through monotonically, so mid-loop `.tempo` /
        // `.timeSignature` meta events fire on iteration 1 only and
        // never re-fire. Seeking via `currentPositionInBeats` here
        // reruns AVAudioSequencer's tempo-track event scan up to the
        // new position, restoring the tempo trajectory for every
        // iteration.
        if let loop = loopRange, rawTick >= loop.endTick {
            wrapToLoopStart(loop)
            return
        }
        let tick = rawTick
        if let frame = timeline.frame(atTick: tick) {
            if frame.cursor != currentCursor {
                currentCursor = frame.cursor
            }
        }
        // Slack of a tick lets us catch the very last frame even if
        // the sequencer reports a sample-accurate beats value just
        // shy of the final onset. Skip while looping — the wrap
        // branch above already handles the boundary, and a stale
        // read here mustn't fire `stop()`.
        if loopRange == nil, tick >= timeline.totalTicks {
            stop()
        }
    }

    /// Seek the playhead back to the loop's start and resume. Driven by
    /// `tickCursor` when the polled position reaches the loop end.
    func wrapToLoopStart(_ loop: LoopRange) {
        guard let sequencer, let timeline else { return }
        let startBeats =
            Double(loop.startTick) / Double(timeline.division)
        sequencer.currentPositionInBeats = startBeats
        // Writing `currentPositionInBeats` while the sequencer is
        // playing halts it — restart immediately so audio keeps
        // flowing. start() on an already-running sequencer is a
        // no-op, but Apple's setter halts before the assignment
        // returns, so we must always re-start here.
        try? sequencer.start()
        // The backward seek re-fires the SMF's tick-0 programChange via
        // AVAudioSequencer's controller chase, overwriting any
        // mixer-driven program override with the score's baked-in
        // default. Re-assert program selection so the user's program
        // choice survives every loop iteration, exactly as
        // `play(from:in:)` does after its own `sequencer.start()`.
        // (CC 7 volume / mute / solo no longer needs racing here: it is
        // stripped from the SMF for mixer-managed channels in
        // `postProcessForMIDISynth`, so the chase can't clobber it.
        // `applyMixerState()` stays as a cheap belt-and-suspenders.)
        reapplyMixerPrograms()
        applyMixerState()
        if let frame = timeline.frame(atTick: loop.startTick) {
            currentCursor = frame.cursor
        }
    }

    /// Stop the engine and release samplers. Safe to call multiple
    /// times; subsequent `prepare(score:)` calls will spin it back up.
    public func teardown() {
        stop()
        clearLoop()
        sequencer = nil
        sequencerScore = nil
        // Quiesce the render thread BEFORE detaching any node. `stop()` above
        // only *pauses* the engine (it calls `engine.pause()`), which leaves
        // AURemoteIO's IO thread and the output unit's render-notify block
        // live. Detaching / disconnecting the synth or the metronome sampler
        // out from under a paused-but-not-stopped engine races the in-flight
        // render cycle and faults on the IO thread — observed in Crashlytics
        // as EXC_BAD_ACCESS in `_Block_copy` (render-notify) and in
        // `ProcessMono` / `SamplerNote::Render` (MIDISynth voice render). A
        // full `engine.stop()` tears the IO thread down synchronously, so the
        // graph edits below run with no renderer active.
        //
        // `engine.stop()` is unconditional: `pause()` already cleared
        // `isRunning`, so the previous `if engine.isRunning` guard skipped the
        // hard stop entirely and left the graph being mutated under a live
        // render unit. `stop()` is a safe no-op on an already-stopped engine.
        engine.stop()
        if let synth {
            engine.disconnectNodeOutput(synth)
            engine.detach(synth)
            self.synth = nil
        }
        staffMIDIChannels.removeAll()
        staffIsDrum.removeAll()
        metronome.teardown()
    }
}
