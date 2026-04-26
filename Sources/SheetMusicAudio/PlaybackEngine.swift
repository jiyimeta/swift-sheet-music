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
    case stopped, playing, paused
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
@MainActor
public final class PlaybackEngine: ObservableObject {
    private let resolver: SoundfontResolver
    private let engine = AVAudioEngine()
    /// `AVAudioUnitSampler` per staff index. Re-built on each call
    /// to `prepare(score:)`.
    private var staffSamplers: [Int: AVAudioUnitSampler] = [:]
    /// Used to silence pending preview note-offs when the engine is
    /// torn down or a new score is prepared.
    private let previewQueue = DispatchQueue(
        label: "swift-sheet-music.playback.preview",
        qos: .userInteractive)

    /// Sequencer used for full-score playback. Lazily built the
    /// first time `play(...)` is called for a given score.
    private var sequencer: AVAudioSequencer?
    /// Score the sequencer was built from. When `prepare` runs
    /// against a different score, the sequencer is torn down so
    /// the next `play` rebuilds it.
    private var sequencerScore: Score?
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
    /// MuseScore-style toggle for the metronome click during full-
    /// score playback. Defaults to `true`; flipping it mid-playback
    /// mutes / unmutes the live metronome track without rebuilding
    /// the sequencer.
    @Published public var isMetronomeEnabled = true {
        didSet { metronome.isEnabled = isMetronomeEnabled }
    }

    public init(soundfontResolver: SoundfontResolver) {
        self.resolver = soundfontResolver
        self.metronome = MetronomeController(engine: engine)
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
    public func prepare(score: Score) throws {
        // Stop any in-flight playback before tearing down samplers.
        stop()
        sequencer = nil
        sequencerScore = nil
        timeline = PlaybackTimeline(score: score)
        metronomeBeats = PlaybackTimeline.metronomeBeats(score: score)
        metronome.prepare(soundfontURL: resolver.defaultGMSoundfontURL)
        // Tear down any samplers from a previous score.
        for sampler in staffSamplers.values {
            engine.disconnectNodeOutput(sampler)
            engine.detach(sampler)
        }
        staffSamplers.removeAll()

        #if os(iOS) || os(tvOS) || os(watchOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
        #endif

        for (idx, _) in score.staves.enumerated() {
            let part = idx < score.parts.count
                ? score.parts[idx]
                : nil
            let channel = part?.instrument.channels.first
                ?? InstrumentChannel()
            let isDrums = part?.instrument.useDrumset == true
            let bank = UInt8(clamping: channel.bank)
            let program = UInt8(clamping: channel.program)

            let url = resolver.soundfontURL(
                forBank: bank, program: program)
                ?? resolver.defaultGMSoundfontURL

            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(
                sampler,
                to: engine.mainMixerNode,
                format: nil)
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
                        bankLSB: bankLSB)
                } catch {
                    // Don't fail the whole `prepare` if one staff's
                    // soundfont is missing or malformed; leave the
                    // sampler attached so the routing graph stays
                    // intact and that staff is just silent.
                }
            }
            staffSamplers[idx] = sampler
        }

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
        velocity: UInt8 = 96
    ) {
        guard let pitch = pitch(for: noteID, in: score) else { return }
        guard let sampler = staffSamplers[noteID.staffIndex]
        else { return }
        sampler.startNote(
            pitch, withVelocity: velocity, onChannel: 0)
        previewQueue.asyncAfter(
            deadline: .now() + duration
        ) { [weak sampler] in
            sampler?.stopNote(pitch, onChannel: 0)
        }
    }

    /// MIDI pitch for the chord-note this `NoteID` references, or
    /// `nil` if the score's structure has changed since the ID was
    /// created (out-of-range index, no longer a chord, etc.).
    private func pitch(
        for noteID: NoteID, in score: Score
    ) -> UInt8? {
        guard noteID.staffIndex < score.staves.count else {
            return nil
        }
        let staff = score.staves[noteID.staffIndex]
        guard noteID.measureIndex < staff.measures.count else {
            return nil
        }
        let measure = staff.measures[noteID.measureIndex]
        guard noteID.voiceIndex < measure.voices.count else {
            return nil
        }
        let voice = measure.voices[noteID.voiceIndex]
        guard noteID.elementIndex < voice.elements.count,
              case .chord(let chord) =
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
        guard let timeline else { return }
        do {
            if sequencer == nil || sequencerScore != score {
                try buildSequencer(for: score)
                sequencerScore = score
            }
            guard let sequencer else { return }
            // Position. AVAudioSequencer expects beats; `currentPositionInSeconds`
            // is the convenient entry point and works regardless of tempo curves.
            if let cursor, let frame = timeline.frame(forCursor: cursor) {
                sequencer.currentPositionInSeconds = frame.timeSeconds
                currentCursor = frame.cursor
            } else if state == .stopped {
                sequencer.currentPositionInSeconds = 0
                currentCursor = timeline.frames.first?.cursor
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

    /// Pause playback at the current position. `play(...)` resumes
    /// from there.
    public func pause() {
        sequencer?.stop()
        stopCursorTimer()
        state = .paused
    }

    /// Stop playback and rewind to the start. Different from
    /// `pause()` — the next `play` starts from the beginning (or
    /// from the supplied item).
    public func stop() {
        sequencer?.stop()
        sequencer?.currentPositionInSeconds = 0
        stopCursorTimer()
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
            beats: metronomeBeats, division: midi.division))
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
        sequencer.prepareToPlay()
        self.sequencer = sequencer
    }

    private func startCursorTimer() {
        stopCursorTimer()
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            repeats: true
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
        // Auto-stop at the end. AVAudioSequencer doesn't fire a
        // "finished" callback, so we detect end-of-piece by the
        // absence of more frames past the current time.
        let t = sequencer.currentPositionInSeconds
        if !sequencer.isPlaying {
            stopCursorTimer()
            state = .stopped
            return
        }
        if let frame = timeline.frame(atTime: t) {
            if frame.cursor != currentCursor {
                currentCursor = frame.cursor
            }
        }
        if t >= timeline.totalSeconds + 0.05 {
            stop()
        }
    }

    /// Stop the engine and release samplers. Safe to call multiple
    /// times; subsequent `prepare(score:)` calls will spin it back up.
    public func teardown() {
        stop()
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
