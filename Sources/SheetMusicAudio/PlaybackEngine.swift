// swiftlint:disable file_length
@preconcurrency import AVFoundation
import Foundation
import SheetMusicCore
import SheetMusicMIDI

/// Audio playback for `Score`s, backed by `AVAudioEngine` +
/// per-staff `AVAudioUnitMIDIInstrument`s (AUMIDISynth).
///
/// Each staff in `prepare(score:)` gets its own MIDISynth instance,
/// with the matching SoundFont preset loaded via the supplied
/// `SoundfontResolver`. Routing one synth per staff (rather than
/// one per unique `(bank, program)` pair) gives the host control
/// over per-staff volume / pan / mute knobs in a future revision —
/// the routing graph already has the granularity baked in.
///
/// AUMIDISynth (`kAudioUnitSubType_MIDISynth`) is used in preference
/// to `AVAudioUnitSampler` because AUSampler ignores RPN 0,0 (Pitch
/// Bend Sensitivity) — its bend range is hard-coded to ±2 semitones,
/// which audibly truncates portamento glissandi we render at ±12.
/// See `MIDISynthBuilder` for the wrapper that builds and configures
/// each instrument.
///
/// Phase 1 only exposes `playPreview(...)` (a brief noteOn/Off pair
/// triggered when a single note is selected). Timeline-driven
/// playback for the entire score lands in a later phase.
@MainActor
@Observable
public final class PlaybackEngine { // swiftlint:disable:this type_body_length
    private let resolver: SoundfontResolver
    private let engine = AVAudioEngine()
    /// AUMIDISynth per staff index. Re-built on each call to
    /// `prepare(score:)`.
    private var staffSamplers: [Int: AVAudioUnitMIDIInstrument] = [:]
    /// SoundFont-load parameters cached per staff so the mixer's
    /// program picker can swap the GM patch on a sampler without
    /// having to consult the `Score` again.
    private var staffLoadParams: [Int: StaffLoadParams] = [:]

    struct StaffLoadParams {
        var bankLSB: UInt8
        var isDrums: Bool
    }

    /// Used to silence pending preview note-offs when the engine is
    /// torn down or a new score is prepared.
    private let previewQueue = DispatchQueue(
        label: "swift-sheet-music.playback.preview",
        qos: .userInteractive,
    )

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

    public init(soundfontResolver: SoundfontResolver) {
        resolver = soundfontResolver
        metronome = MetronomeController(engine: engine)
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

    // MARK: Internal accessors for `PlaybackEngine+Export`

    func setStateForExport(_ newState: PlaybackState) {
        state = newState
    }

    func exportTimeline() -> PlaybackTimeline? {
        timeline
    }

    /// Snapshot of mutable engine state captured at export start, so
    /// the export pipeline can reproduce live mixer / metronome /
    /// rate behaviour on its own dedicated `AVAudioEngine` without
    /// reaching back into the live engine while rendering.
    struct ExportEngineSnapshot {
        let resolver: SoundfontResolver
        let mixerChannels: [MixerChannel]
        let metronomeEnabled: Bool
        let metronomeVolume: Float
        let rate: Float
        let metronomeBeats: [MetronomeBeat]
    }

    func exportEngineSnapshot() -> ExportEngineSnapshot {
        ExportEngineSnapshot(
            resolver: resolver,
            mixerChannels: mixerChannels,
            metronomeEnabled: metronome.isEnabled,
            metronomeVolume: metronome.volume,
            rate: pendingRate,
            metronomeBeats: metronomeBeats,
        )
    }

    // MARK: Internal accessors for `PlaybackEngine+Mixer`

    func staffSampler(at idx: Int) -> AVAudioUnitMIDIInstrument? {
        staffSamplers[idx]
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

    /// Reload the staff `idx` synth with a new GM `program`,
    /// keeping the staff's existing bank / drumset choice. Does
    /// nothing if the synth isn't built yet (engine never
    /// prepared) or the resolver returns no SoundFont URL — the
    /// existing patch keeps playing in that case.
    func loadProgram(forStaff idx: Int, program: UInt8) {
        guard
            let instrument = staffSamplers[idx],
            let params = staffLoadParams[idx],
            let url = resolver.soundfontURL(
                forBank: params.bankLSB, program: program, isDrums: params.isDrums,
            )
            ?? resolver.defaultGMSoundfontURL
        else { return }
        // MIDISynth uses standard MIDI bank-select semantics. Drum
        // selection is resolved via MIDI channel 9 at play time, not
        // via a magic bank-MSB byte (unlike AUSampler).
        try? MIDISynthBuilder.loadSoundFont(
            into: instrument,
            url: url,
            bankMSB: 0,
            bankLSB: params.bankLSB,
            program: program,
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
        // Metronome always plays GM percussion (hi/low wood block on
        // notes 76 / 77). Ask the resolver for the drum kit at
        // (bank: 0, program: 0, isDrums: true) so a host that doesn't
        // ship a full GM SoundFont can still serve the metronome from
        // a per-(bank, program) split file. Falls back to the GM URL
        // for hosts that haven't moved over.
        let metronomeURL =
            resolver.soundfontURL(forBank: 0, program: 0, isDrums: true)
            ?? resolver.defaultGMSoundfontURL
        metronome.prepare(soundfontURL: metronomeURL)
        // Tear down any samplers from a previous score.
        for sampler in staffSamplers.values {
            engine.disconnectNodeOutput(sampler)
            engine.detach(sampler)
        }
        staffSamplers.removeAll()
        staffLoadParams.removeAll()

        #if os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        #endif

        for (idx, entry) in score.allStaves.enumerated() {
            let part = score.part(at: entry.address)
            let channel = part?.instrument.channels.first
                ?? InstrumentChannel()
            let isDrums = part?.instrument.useDrumset == true
            let bank = UInt8(clamping: channel.bank)
            let program = UInt8(clamping: channel.program)

            let url = resolver.soundfontURL(
                forBank: bank, program: program, isDrums: isDrums,
            )
                ?? resolver.defaultGMSoundfontURL

            let instrument = MIDISynthBuilder.make()
            engine.attach(instrument)
            engine.connect(
                instrument,
                to: engine.mainMixerNode,
                format: nil,
            )
            if let url {
                // Don't fail the whole `prepare` if one staff's
                // soundfont is missing or malformed; leave the
                // synth attached so the routing graph stays
                // intact and that staff is just silent.
                try? MIDISynthBuilder.loadSoundFont(
                    into: instrument,
                    url: url,
                    bankMSB: 0,
                    bankLSB: bank,
                    program: program,
                )
            }
            // The renderer emits pitch-bend ramps assuming RPN 0,0
            // (Pitch Bend Sensitivity) = 12 semitones (see
            // `MidiRenderer+Header`'s RPN block). Pre-configure every
            // melodic channel here so the very first portamento
            // glissando on a fresh score plays at the intended bend
            // width — the SMF's tick-0 RPN setup loses a race against
            // pitch-bend events at later ticks on first play.
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: instrument, semitones: 12, onChannel: ch,
                )
            }
            staffSamplers[idx] = instrument
            staffLoadParams[idx] = StaffLoadParams(
                bankLSB: bank, isDrums: isDrums,
            )
        }

        rebuildMixerChannels(for: score)
        applyMixerState()

        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Briefly play the note identified by `noteID` on its staff's
    /// sampler. Used by the host when the user clicks / taps a single
    /// note — mirrors MuseScore's "preview on selection" behavior.
    /// Calls are non-blocking; the matching note-off is scheduled on
    /// a high-QoS background queue.
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
        guard let instrument = staffSamplers[flatIdx]
        else { return }
        instrument.startNote(
            pitch, withVelocity: velocity, onChannel: 0,
        )
        previewQueue.asyncAfter(
            deadline: .now() + duration,
        ) { [weak instrument] in
            instrument?.stopNote(pitch, onChannel: 0)
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
            // to each staff's MIDISynth — but BEFORE the sequencer
            // fires its tick-0 events. Without this the SMF's own
            // RPN setup loses a race with the first portamento on
            // the very first play after `prepare(score:)`, leaving
            // the bend clamped at the AU's ±2-semitone default.
            // See `MIDISynthBuilder.setPitchBendSensitivity` for
            // why the C-API path matters here.
            for instrument in staffSamplers.values {
                for ch: UInt8 in 0 ..< 16 where ch != 9 {
                    MIDISynthBuilder.setPitchBendSensitivity(
                        into: instrument, semitones: 12, onChannel: ch,
                    )
                }
            }
            try sequencer.start()
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
    static func postProcessForMIDISynth(midi: inout MidiFile) {
        for trackIdx in midi.tracks.indices {
            var out: [TimedMidiEvent] = []
            out.reserveCapacity(midi.tracks[trackIdx].events.count + 8)
            for event in midi.tracks[trackIdx].events {
                if case let .controlChange(_, controller, _) = event.event,
                   controller == 121
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
        // the in-memory `MidiFile` *before* serialising — the
        // public `MidiRenderer.render` / `SheetMusic.exportMIDI`
        // path stays free of metronome events; only this playback
        // pipeline injects them.
        var midi = try MidiRenderer.render(score: score)
        midi.tracks.append(metronome.metronomeTrack(
            beats: metronomeBeats, division: midi.division,
        ))
        Self.postProcessForMIDISynth(midi: &midi)
        let bytes = try MidiWriter.write(midi)
        try sequencer.load(from: bytes, options: [])
        // Route each track to its matching staff sampler. The
        // metronome track is appended last and is picked up by
        // `metronome.attach(to:)` below.
        for (i, track) in sequencer.tracks.enumerated() {
            if let instrument = staffSamplers[i] {
                track.destinationAudioUnit = instrument
            }
        }
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        // Assert pitch-bend sensitivity once the sequencer knows its
        // destination AUs but before any play. This pairs with the
        // matching call in `play(...)` — the redundancy is defensive,
        // since which side wins the race against tick-0 SMF events
        // varies between fresh-build vs. cached-sequencer paths.
        for instrument in staffSamplers.values {
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: instrument, semitones: 12, onChannel: ch,
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
            let startBeats =
                Double(loop.startTick) / Double(timeline.division)
            sequencer.currentPositionInBeats = startBeats
            // Writing `currentPositionInBeats` while the sequencer is
            // playing halts it — restart immediately so audio keeps
            // flowing. start() on an already-running sequencer is a
            // no-op, but Apple's setter halts before the assignment
            // returns, so we must always re-start here.
            try? sequencer.start()
            if let frame = timeline.frame(atTick: loop.startTick) {
                currentCursor = frame.cursor
            }
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

    /// Stop the engine and release samplers. Safe to call multiple
    /// times; subsequent `prepare(score:)` calls will spin it back up.
    public func teardown() {
        stop()
        clearLoop()
        sequencer = nil
        sequencerScore = nil
        for sampler in staffSamplers.values {
            engine.disconnectNodeOutput(sampler)
            engine.detach(sampler)
        }
        staffSamplers.removeAll()
        metronome.teardown()
        if engine.isRunning {
            engine.stop()
        }
    }
}
