// swiftlint:disable file_length
import AVFoundation
import Combine
import Foundation
import SheetMusicCore
import SheetMusicMIDI

/// Audio playback for `Score`s, backed by `AVAudioEngine` +
/// per-staff `AVAudioUnitSampler`s.
///
/// Each staff in `prepare(score:)` gets its own sampler, with the
/// matching SoundFont preset loaded via the supplied
/// `SoundfontResolver`. Routing one sampler per staff (rather than
/// one per unique `(bank, program)` pair) gives the host control
/// over per-staff volume / pan / mute knobs in a future revision —
/// the routing graph already has the granularity baked in.
///
/// Phase 1 only exposes `playPreview(...)` (a brief noteOn/Off pair
/// triggered when a single note is selected). Timeline-driven
/// playback for the entire score lands in a later phase.
/// State machine for full-score playback. Drives any UI that
/// needs to switch between play / pause icons.
public enum PlaybackState: Sendable, Equatable {
    case stopped, playing, paused, exporting
}

/// Half-open tick range `[startTick, endTick)` the engine should
/// loop while playing. Tick-based rather than cursor-based because
/// `setLoop(from:throughEndOf:)` wraps at an item's offset, which
/// rarely coincides with a `ScoreCursor` column. Hosts that want a
/// cursor for the boundaries can resolve via
/// `PlaybackTimeline.frame(atTick:)`.
public struct LoopRange: Sendable, Equatable {
    public let startTick: Int
    public let endTick: Int

    public init(startTick: Int, endTick: Int) {
        self.startTick = startTick
        self.endTick = endTick
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
@MainActor
public final class PlaybackEngine: ObservableObject { // swiftlint:disable:this type_body_length
    private let resolver: SoundfontResolver
    private let engine = AVAudioEngine()
    /// `AVAudioUnitSampler` per staff index. Re-built on each call
    /// to `prepare(score:)`.
    private var staffSamplers: [Int: AVAudioUnitSampler] = [:]
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

    @Published public private(set) var state: PlaybackState = .stopped
    @Published public private(set) var currentCursor: ScoreCursor?
    /// When non-nil, every track in the sequencer is configured with
    /// `lengthInBeats = endTick / division` and
    /// `loopRange = (start: startTick / division, length: …)`, with
    /// `isLoopingEnabled = true`. AVAudioSequencer wraps natively at
    /// the boundary (sample-accurate, no audible glitch). Setting or
    /// clearing the loop pauses playback first because live
    /// mutations on a running track aren't safely supported by the
    /// sequencer; `play(...)` and `seek(...)` snap back into the
    /// region when called outside it.
    @Published public private(set) var loopRange: LoopRange?
    /// Per-track `lengthInBeats` snapshot taken before the loop
    /// truncates each track. Restored by `clearLoop()` so the score
    /// past the loop end is playable again. Re-snapshotted whenever
    /// `buildSequencer` recreates the tracks.
    private var originalTrackLengths: [Double]?
    /// One strip per staff plus a metronome strip. Rebuilt on each
    /// `prepare(score:)` call; mutated through `setVolume / setMuted
    /// / setSoloed`. Hosts bind a SwiftUI mixer view directly to
    /// this array and re-render on change.
    @Published public private(set) var mixerChannels: [MixerChannel] = []

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

    // MARK: Internal accessors for `PlaybackEngine+Mixer`

    func staffSampler(at idx: Int) -> AVAudioUnitSampler? {
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

    /// Reload the staff `idx` sampler with a new GM `program`,
    /// keeping the staff's existing bank / drumset choice. Does
    /// nothing if the sampler isn't built yet (engine never
    /// prepared) or the resolver returns no SoundFont URL — the
    /// existing patch keeps playing in that case.
    func loadProgram(forStaff idx: Int, program: UInt8) {
        guard
            let sampler = staffSamplers[idx],
            let params = staffLoadParams[idx],
            let url = resolver.soundfontURL(
                forBank: params.bankLSB, program: program, isDrums: params.isDrums,
            )
            ?? resolver.defaultGMSoundfontURL
        else { return }
        let bankMSB: UInt8 = params.isDrums
            ? UInt8(kAUSampler_DefaultPercussionBankMSB)
            : UInt8(kAUSampler_DefaultMelodicBankMSB)
        try? sampler.loadSoundBankInstrument(
            at: url,
            program: program,
            bankMSB: bankMSB,
            bankLSB: params.bankLSB,
        )
    }

    /// Build per-staff samplers, load their SoundFont presets, and
    /// start the audio engine. Idempotent: calling again with a
    /// different score replaces the samplers.
    ///
    /// Synchronous and potentially slow on first call:
    /// `AVAudioUnitSampler.loadSoundBankInstrument` blocks while
    /// the SF2 file is parsed (tens of ms per file is typical, more
    /// on iPhone for the full GM SF2). Wrap the call in
    /// `Task.detached(priority: .userInitiated) { … }` if you want
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

            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(
                sampler,
                to: engine.mainMixerNode,
                format: nil,
            )
            if let url {
                // `AVAudioUnitSampler` resolves a preset via
                // (bank MSB, bank LSB, program). For SF2 files, the
                // melodic / percussion split is encoded in the bank
                // MSB (0x79 / 0x78); the LSB carries the SF2 file's
                // bank number, which our `Channel.bank` field maps
                // to.
                let bankMSB: UInt8 = isDrums
                    ? UInt8(kAUSampler_DefaultPercussionBankMSB)
                    : UInt8(kAUSampler_DefaultMelodicBankMSB)
                let bankLSB: UInt8 = bank
                do {
                    try sampler.loadSoundBankInstrument(
                        at: url,
                        program: program,
                        bankMSB: bankMSB,
                        bankLSB: bankLSB,
                    )
                } catch {
                    // Don't fail the whole `prepare` if one staff's
                    // soundfont is missing or malformed; leave the
                    // sampler attached so the routing graph stays
                    // intact and that staff is just silent.
                }
            }
            staffSamplers[idx] = sampler
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
        guard let sampler = staffSamplers[flatIdx]
        else { return }
        sampler.startNote(
            pitch, withVelocity: velocity, onChannel: 0,
        )
        previewQueue.asyncAfter(
            deadline: .now() + duration,
        ) { [weak sampler] in
            sampler?.stopNote(pitch, onChannel: 0)
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
    /// Pauses playback when called while playing — live track-length
    /// mutations on a running AVAudioSequencer aren't safely
    /// supported. The host resumes via `play(...)` after.
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

    /// Disable looping and restore each track's original length so
    /// playback past the previous loop end is audible again. Pauses
    /// first if currently playing — same rationale as `setLoop`.
    public func clearLoop() {
        guard state != .exporting else { return }
        if state == .playing {
            pause()
        }
        if let sequencer, let originals = originalTrackLengths {
            for (i, track) in sequencer.tracks.enumerated()
                where i < originals.count
            {
                track.isLoopingEnabled = false
                track.lengthInBeats = originals[i]
            }
        }
        originalTrackLengths = nil
        loopRange = nil
    }

    private func apply(loop: LoopRange) {
        if state == .playing {
            pause()
        }
        loopRange = loop
        applyLoopToSequencerTracks()
    }

    /// Push the current `loopRange` onto every track in the
    /// sequencer. Called from `apply(loop:)` and from
    /// `buildSequencer` (so a loop set before the first `play(...)`
    /// survives the lazy sequencer build).
    private func applyLoopToSequencerTracks() {
        guard let timeline, let sequencer, let loop = loopRange
        else { return }
        if originalTrackLengths == nil {
            originalTrackLengths = sequencer.tracks.map(\.lengthInBeats)
        }
        let startBeats = Double(loop.startTick) / Double(timeline.division)
        let endBeats = Double(loop.endTick) / Double(timeline.division)
        let length = endBeats - startBeats
        for track in sequencer.tracks {
            track.lengthInBeats = endBeats
            track.loopRange = AVBeatRange(
                start: startBeats, length: length,
            )
            track.isLoopingEnabled = true
        }
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
    public var currentTimeSeconds: TimeInterval {
        guard let timeline, let sequencer else { return 0 }
        let tick = Int(
            (sequencer.currentPositionInBeats * Double(timeline.division))
                .rounded(),
        )
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
        let bytes = try MidiWriter.write(midi)
        try sequencer.load(from: bytes, options: [])
        // Route each track to its matching staff sampler. The
        // metronome track is appended last and is picked up by
        // `metronome.attach(to:)` below.
        for (i, track) in sequencer.tracks.enumerated() {
            if let sampler = staffSamplers[i] {
                track.destinationAudioUnit = sampler
            }
        }
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        self.sequencer = sequencer
        // Cached lengths refer to the previous (now-released) tracks;
        // discard so `applyLoopToSequencerTracks` re-snapshots from
        // the fresh ones.
        originalTrackLengths = nil
        if loopRange != nil {
            applyLoopToSequencerTracks()
        }
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
        // `AVAudioSequencer.currentPositionInBeats` keeps advancing
        // monotonically even while individual tracks wrap via
        // `AVMusicTrack.loopRange` — only the per-track playhead
        // wraps, not the player's beat counter. Fold the raw counter
        // back into `[startTick, endTick)` ourselves so the cursor
        // tracks audio.
        let tick: Int
        if let loop = loopRange, rawTick >= loop.endTick {
            let len = loop.endTick - loop.startTick
            tick = loop.startTick + (rawTick - loop.startTick) % len
        } else {
            tick = rawTick
        }
        if let frame = timeline.frame(atTick: tick) {
            if frame.cursor != currentCursor {
                currentCursor = frame.cursor
            }
        }
        // Slack of a tick lets us catch the very last frame even if
        // the sequencer reports a sample-accurate beats value just
        // shy of the final onset. Skip while looping — the
        // sequencer wraps natively inside `[startTick, endTick)`,
        // and a stale read at the boundary mustn't fire `stop()`.
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
