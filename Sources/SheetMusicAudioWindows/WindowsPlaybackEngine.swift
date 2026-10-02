// swiftlint:disable file_length
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI
import Synchronization

/// Score playback on Windows, with the Apple `PlaybackEngine`'s operations under the same names and argument labels.
///
/// **Shape.** Android's, on the same shared core: the score's SMF (`PreparedPlayback.render` → `MidiSynthPostProcess`,
/// what `AudioMidiBridge.renderMidi` gives Android) plays through FluidSynth's own MIDI player on one synth, and the
/// metronome through a second synth + player over `MetronomeSequenceBuilder`'s click sequence (Android's
/// `MetronomeMixer`, the SwiftySynth backend's second sequencer). The metronome is never taken out of the render, so
/// the two transports stay in step and a mute is a level, not a reload. Output is WASAPI shared mode (`CWASAPI`).
///
/// **Time.** Both players run on the render thread's sample clock (`player.timing-source = sample`). Every position
/// this engine reports is the score player's tick — unrolled, as the SMF is — projected onto the notated timeline
/// (`PlaybackUnroll`, `PlaybackTimeline`), exactly as the Apple engine's AUMIDISynth path reads its sequencer's beat.
/// The device clock (`IAudioClock`) is not used for position: it counts frames the device played, which a seek or a
/// loop wrap does not rewind. Decisions that must land on the beat — the count-in's handover, the loop's wrap, the end
/// of the score, a preview's note-off — are taken on the render thread between 64-frame chunks (`PlaybackCore`).
///
/// **Threading.** Control calls come from one thread (folino's main actor), as the Apple engine's do from its
/// `@MainActor`; the engine is `@unchecked Sendable` rather than `@MainActor` so it has no UI framework to depend on.
/// Changes that happen on their own — the end of the score, the output device going and coming back — are reported
/// through `onEvent`, on the output thread.
///
/// **Output.** The stream runs from the first `prepare` to `teardown`: a pause or stop happens in the players (all
/// sounds off), so previews sound while paused with nothing to restart, and releases ring out. The stream follows the
/// default output device (`AudioDeviceStream`), and an engine made with no device at all works and stays silent
/// until one appears.
public final class WindowsPlaybackEngine: @unchecked Sendable {
    /// Something that happened without a control call asking for it. Delivered on the output thread: hop to the UI
    /// before touching it.
    public enum Event: Sendable, Equatable {
        /// Playback reached the end of the score and stopped (`state` is now `.stopped`, the cursor cleared) — the
        /// Apple engine's end-of-score `stop()`.
        case reachedEnd
        /// The output device went away or the default device changed. The stream is closed and being reopened on the
        /// current default; `state` and the position are kept, and nothing sounds until `deviceRecovered`.
        case deviceLost
        /// Output resumed on the current default device.
        case deviceRecovered
    }

    /// What the output looks like and what it has been through, for a probe to report.
    public struct Diagnostics: Sendable, Equatable {
        /// The rate the synths render at, fixed for the engine's life (the default device's rate when output first
        /// opened, 48 kHz if there was no device).
        public let sampleRate: Double
        /// The shared buffer's size in frames on the current device.
        public let bufferFrames: Int
        /// The stream latency Windows reports for the current device.
        public let latencySeconds: Double
        /// Times the device found nothing queued while running — each an audible gap.
        public let underruns: Int
        public let hasOutputDevice: Bool
        /// Streams reopened after a device change or loss (or opened after starting with no device).
        public let deviceRebuilds: Int
        /// Close to reopen, for the last rebuild.
        public let lastDeviceRebuildSeconds: Double?
        /// Loop wraps since the last prepare.
        public let loopWraps: Int
        /// How many ticks past the count-in's end the metronome was when the last handover to the score happened.
        public let lastCountInHandoverLateTicks: Int?
        /// Whether the score synth has a SoundFont. A missing or unreadable one is not an error — the engine plays
        /// silence, as the Apple and Android engines do — so this is where it shows.
        public let soundFontLoaded: Bool
    }

    /// The score last prepared, and everything derived from it once.
    struct LoadedScore {
        let score: Score
        let derivation: PlaybackScoreDerivation
        let rendered: MidiFile
        let sequences: LoadedSequences
    }

    private var resolver: SoundfontResolver
    private let metronomeClickProvider: MetronomeClickProvider?
    private var clickResolver: MetronomeClickResolver
    let core = PlaybackCore()
    private(set) var output: AudioDeviceStream?
    private(set) var loaded: LoadedScore?

    /// Where generated metronome-click SoundFonts go (`MetronomeClickResolver`): the user's caches directory, as on
    /// the Apple engine.
    static let clickCacheDirectory: URL? = (
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory,
    ).appendingPathComponent("SheetMusicMetronomeClicks", isDirectory: true)

    /// Nothing is opened here: the output device and the synths come with the first `prepare(score:)`, so an engine
    /// can be made, and survives, with no audio device at all.
    public init(soundfontResolver: SoundfontResolver, metronomeClickProvider: MetronomeClickProvider? = nil) {
        resolver = soundfontResolver
        self.metronomeClickProvider = metronomeClickProvider
        clickResolver = MetronomeClickResolver(
            provider: metronomeClickProvider, soundfontResolver: soundfontResolver,
            cacheDirectory: Self.clickCacheDirectory,
        )
    }

    deinit {
        teardown()
    }

    // MARK: Observed state

    public var state: PlaybackState {
        core.shared.withLock { $0.state }
    }

    /// The notated position sounding now: the score player's tick through the unroll map, pinned to the start during
    /// a count-in. `nil` before a play and after a stop, as on the Apple engine.
    public var currentCursor: ScoreCursor? {
        guard let loaded else { return nil }
        let (hasCursor, tick) = core.shared.withLock { ($0.hasCursor, $0.foldedReportedScoreTick) }
        guard hasCursor else { return nil }
        return loaded.derivation.timeline.frame(atTick: loaded.derivation.unroll.notatedTick(fromUnrolled: tick))?
            .cursor
    }

    public var loopRange: LoopRange? {
        core.shared.withLock { $0.loopRange }
    }

    /// One strip per (part × instrument), plus the metronome — `PlaybackChannelLayout`'s, as on the Apple engine.
    public var mixerChannels: [MixerChannel] {
        core.shared.withLock { $0.mixerChannels }
    }

    /// Always `false`: SoundFonts load synchronously inside `prepare(score:)` / `reloadSoundfont(resolver:)`, as on
    /// the Apple engine's AUMIDISynth path.
    public var isPreparingSoundfont: Bool {
        false
    }

    /// Current playback position in seconds, snapped to the frame sounding (the Apple engine's AUMIDISynth
    /// `currentTimeSeconds`): during a count-in the start position's time, and in a loop the folded, audible one.
    public var currentTimeSeconds: TimeInterval {
        guard let loaded else { return 0 }
        let tick = core.shared.withLock { $0.foldedReportedScoreTick }
        return loaded.derivation.timeline.frame(atTick: loaded.derivation.unroll.notatedTick(fromUnrolled: tick))?
            .timeSeconds ?? 0
    }

    /// Total playable duration in seconds for the loaded score (notated). Zero before `prepare(score:)`.
    public var totalTimeSeconds: TimeInterval {
        loaded?.derivation.timeline.totalSeconds ?? 0
    }

    /// Like `currentTimeSeconds`, but continuous between frames — the Apple engine's `currentTimeSecondsContinuous`,
    /// for a pitch bar or anything else that moves between chords.
    public var currentTimeSecondsContinuous: TimeInterval {
        guard let derivation = loaded?.derivation else { return 0 }
        let tick = core.shared.withLock { $0.foldedReportedScoreTick }
        return derivation.timeline.seconds(atTick: derivation.unroll.notatedTick(fromUnrolled: Double(tick)))
    }

    /// The loaded score's derivation, for the probe's read-backs.
    var loadedDerivation: PlaybackScoreDerivation? {
        loaded?.derivation
    }

    public var diagnostics: Diagnostics {
        let stats = output?.currentStats ?? AudioDeviceStream.Stats()
        let (wraps, handover, soundFont) = core.shared.withLock { shared in
            (shared.loopWraps, shared.lastHandoverLateTicks, (shared.session?.score.soundFontID ?? -1) >= 0)
        }
        return Diagnostics(
            sampleRate: stats.sampleRate, bufferFrames: stats.bufferFrames, latencySeconds: stats.latencySeconds,
            underruns: stats.underruns, hasOutputDevice: stats.hasDevice, deviceRebuilds: stats.rebuilds,
            lastDeviceRebuildSeconds: stats.lastRebuildSeconds, loopWraps: wraps,
            lastCountInHandoverLateTicks: handover, soundFontLoaded: soundFont,
        )
    }

    /// Called on the output thread for changes no control call asked for; see `Event`.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { core.shared.withLock { $0.onEvent } }
        set { core.shared.withLock { $0.onEvent = newValue } }
    }

    // MARK: Preparing

    /// Loads `score`: derives its timeline and mixer, renders its SMF and the metronome's, starts the output on first
    /// use and builds the synths. Playback stops, the loop is cleared and the mixer returns to the score's defaults;
    /// rate, tuning, transposition, the master stage and level monitoring survive, as on the Apple engine.
    ///
    /// Synchronous. The SoundFont is loaded only when it is not the one already loaded — an edit's re-prepare keeps
    /// the synth — and for an edited score `replaceScore(with:)` keeps everything but the sequence.
    ///
    /// - Throws: when FluidSynth cannot make a synth or a player, or the SMF cannot be written. Having no output
    ///   device is not an error.
    public func prepare(score: Score) throws {
        try prepareFully(score: score, derivation: PreparedPlayback.derive(score: score), renderedMidi: nil)
    }

    /// Replaces the prepared score while keeping the synths, the mixer, rate, tuning, transposition, the master stage
    /// and the metronome — when the mixer layout is unchanged. A changed layout or an unprepared engine falls back to
    /// the full `prepare(score:)`. Either way playback stops and the loop is cleared, as on the Apple engine.
    @discardableResult
    public func replaceScore(with prepared: PreparedPlayback) throws -> ScoreReplacementOutcome {
        guard let loaded, loaded.derivation.channelLayout == prepared.channelLayout else {
            try prepareFully(prepared)
            return .fullyPrepared
        }
        let sequences = try LoadedSequences(rendered: prepared.renderedMidi, derivation: prepared.derivation)
        let replaced = try core.shared.withLock { shared throws -> Bool in
            shared.stopPlayers(silence: .cut)
            shared.cancelPreviews()
            guard var session = shared.session else { return false }
            // Made and deleted under the lock: see `PlayerHandle.make`.
            let players = try Self.makePlayers(
                for: sequences, score: session.score, metronome: session.metronome, rate: shared.rate,
            )
            Self.deletePlayers(of: session)
            session.sequences = sequences
            session.scorePlayer = players.score
            session.bodyMetronome = players.metronome
            session.countInMetronome = nil
            shared.session = session
            shared.install(prepared.derivation, keepingMixer: true)
            shared.applyTuning()
            shared.reassertChannelState()
            shared.applyMixerState()
            return true
        }
        guard replaced else {
            try prepareFully(prepared)
            return .fullyPrepared
        }
        self.loaded = LoadedScore(
            score: prepared.score, derivation: prepared.derivation, rendered: prepared.renderedMidi,
            sequences: sequences,
        )
        return .swappedInPlace
    }

    /// Swaps the SoundFont resolver and rebuilds the synths on it in place, keeping the position, the playing or
    /// paused transport, the loop, the mixer, rate and tuning — the Apple engine's `restartGraphPreservingState`. The
    /// metronome follows too: its click resolver is rebuilt on the new resolver.
    ///
    /// Before the first `prepare(score:)` this only replaces the resolver. A synth FluidSynth cannot build leaves the
    /// old ones playing; a SoundFont it cannot load plays silence (`diagnostics.soundFontLoaded`).
    public func reloadSoundfont(resolver newResolver: SoundfontResolver) {
        resolver = newResolver
        clickResolver = MetronomeClickResolver(
            provider: metronomeClickProvider, soundfontResolver: newResolver, cacheDirectory: Self.clickCacheDirectory,
        )
        guard let loaded, let output else { return }
        let sampleRate = output.sampleRate
        let rate = core.shared.withLock { $0.rate }
        let scoreSynth: SynthHandle
        let metronomeSynth: SynthHandle
        let players: (score: PlayerHandle, metronome: PlayerHandle)
        do {
            scoreSynth = try SynthHandle.make(sampleRate: sampleRate, soundFontURL: newResolver.defaultGMSoundfontURL)
            do {
                metronomeSynth = try SynthHandle.make(
                    sampleRate: sampleRate, soundFontURL: clickResolver.resolvedSoundFontURL(),
                )
            } catch {
                scoreSynth.delete()
                throw error
            }
            // Neither synth renders yet, so their players can be made outside the lock.
            do {
                players = try Self.makePlayers(
                    for: loaded.sequences, score: scoreSynth, metronome: metronomeSynth, rate: rate,
                )
            } catch {
                scoreSynth.delete()
                metronomeSynth.delete()
                throw error
            }
        } catch {
            return
        }
        let retired = core.shared.withLock { shared -> Session? in
            let old = shared.session
            shared.adopt(Session(
                score: scoreSynth, metronome: metronomeSynth, sequences: loaded.sequences,
                scorePlayer: players.score, bodyMetronome: players.metronome, countInMetronome: nil,
            ))
            return old
        }
        // Nothing renders the old synths any more.
        if let retired {
            Self.deletePlayers(of: retired)
            retired.score.delete()
            retired.metronome.delete()
        }
    }

    private func prepareFully(_ prepared: PreparedPlayback) throws {
        try prepareFully(score: prepared.score, derivation: prepared.derivation, renderedMidi: prepared.renderedMidi)
    }

    private func prepareFully(score: Score, derivation: PlaybackScoreDerivation, renderedMidi: MidiFile?) throws {
        let layout = derivation.channelLayout
        let rendered = try renderedMidi ?? PreparedPlayback.render(score: score, channelLayout: layout)
        let sequences = try LoadedSequences(rendered: rendered, derivation: derivation)
        let sampleRate = startOutputIfNeeded()
        stop()
        let (scoreSynth, metronomeSynth, built) = try synthsToPrepare(sampleRate: sampleRate)

        let retired: Session?
        do {
            retired = try core.shared.withLock { shared throws -> Session? in
                // Players are made and deleted under the lock: see `PlayerHandle.make`.
                let players = try Self.makePlayers(
                    for: sequences, score: scoreSynth, metronome: metronomeSynth, rate: shared.rate,
                )
                let old = shared.session
                shared.cancelPreviews()
                if let old {
                    Self.deletePlayers(of: old)
                }
                // A kept synth goes back to a new synth's state; `reassertChannelState` then sets what the score uses.
                if old?.score.synth == scoreSynth.synth {
                    scoreSynth.systemReset()
                }
                if old?.metronome.synth == metronomeSynth.synth {
                    metronomeSynth.systemReset()
                }
                shared.session = Session(
                    score: scoreSynth, metronome: metronomeSynth, sequences: sequences,
                    scorePlayer: players.score, bodyMetronome: players.metronome, countInMetronome: nil,
                )
                shared.sampleRate = sampleRate
                shared.install(derivation, keepingMixer: false)
                shared.applyTuning()
                shared.reassertChannelState()
                shared.applyMixerState()
                return old
            }
        } catch {
            built.forEach { $0.delete() }
            throw error
        }
        // Nothing renders a replaced synth any more; its players went under the lock.
        if let retired {
            if retired.score.synth != scoreSynth.synth {
                retired.score.delete()
            }
            if retired.metronome.synth != metronomeSynth.synth {
                retired.metronome.delete()
            }
        }
        loaded = LoadedScore(score: score, derivation: derivation, rendered: rendered, sequences: sequences)
    }

    /// The score and metronome synths a prepare installs, and which of them are new. A loaded synth whose SoundFont is
    /// still the one to load is kept: loading a General MIDI SoundFont takes long. Nothing is installed here.
    private func synthsToPrepare(
        sampleRate: Double,
    ) throws -> (score: SynthHandle, metronome: SynthHandle, built: [SynthHandle]) {
        let current = core.shared.withLock { shared in
            shared.session.map { (score: $0.score, metronome: $0.metronome) }
        }
        let scoreURL = resolver.defaultGMSoundfontURL
        let clickURL = clickResolver.resolvedSoundFontURL()
        var built: [SynthHandle] = []
        do {
            let score: SynthHandle
            if let kept = current?.score, kept.soundFontURL == scoreURL, kept.sampleRate == sampleRate {
                score = kept
            } else {
                score = try SynthHandle.make(sampleRate: sampleRate, soundFontURL: scoreURL)
                built.append(score)
            }
            let metronome: SynthHandle
            if let kept = current?.metronome, kept.soundFontURL == clickURL, kept.sampleRate == sampleRate {
                metronome = kept
            } else {
                metronome = try SynthHandle.make(sampleRate: sampleRate, soundFontURL: clickURL)
                built.append(metronome)
            }
            return (score, metronome, built)
        } catch {
            built.forEach { $0.delete() }
            throw error
        }
    }

    /// Starts the output on first use and answers the rate the synths have to render at.
    private func startOutputIfNeeded() -> Double {
        if let output {
            return output.sampleRate
        }
        let core = core
        let stream = AudioDeviceStream(
            render: { buffer, frames in core.render(into: buffer, frames: frames) },
            notify: { notice in core.emit(notice == .lost ? .deviceLost : .deviceRecovered) },
        )
        stream.start()
        output = stream
        return stream.sampleRate
    }

    private static func makePlayers(
        for sequences: LoadedSequences, score: SynthHandle, metronome: SynthHandle, rate: Float,
    ) throws -> (score: PlayerHandle, metronome: PlayerHandle) {
        let scorePlayer = try PlayerHandle.make(on: score, midi: sequences.score, rate: rate)
        do {
            return try (scorePlayer, PlayerHandle.make(on: metronome, midi: sequences.metronome, rate: rate))
        } catch {
            scorePlayer.delete()
            throw error
        }
    }

    private static func deletePlayers(of session: Session) {
        session.scorePlayer.delete()
        session.bodyMetronome.delete()
        session.countInMetronome?.delete()
    }

    // MARK: Teardown

    /// Stops, closes the output and frees the synths. Safe to call more than once; a later `prepare(score:)` starts
    /// everything again. The master stage, rate, tuning and transposition are kept, as on the Apple engine.
    public func teardown() {
        stop()
        let retired = core.shared.withLock { shared -> Session? in
            let session = shared.session
            shared.cancelPreviews()
            shared.session = nil
            shared.strips = []
            shared.loopRange = nil
            shared.transportLoop = nil
            shared.totalTicks = 0
            return session
        }
        output?.stop()
        output = nil
        if let retired {
            Self.deletePlayers(of: retired)
            retired.score.delete()
            retired.metronome.delete()
        }
        loaded = nil
    }
}

/// The two sequences a loaded score plays: the score's own, and the metronome's.
struct LoadedSequences: Sendable {
    /// The unrolled render with the mixer-owned channels' tick-0 program and CC 7 stripped
    /// (`MidiSynthPostProcess`) — the bytes `AudioMidiBridge.renderMidi` hands Android.
    let score: Data
    /// The score's tempo map and a click on every unrolled beat (`MetronomeSequenceBuilder`), the Apple SwiftySynth
    /// backend's and Android's metronome sequence.
    let metronome: Data

    init(rendered: MidiFile, derivation: PlaybackScoreDerivation) throws {
        var midi = rendered
        MidiSynthPostProcess.apply(
            midi: &midi, mixerManagedChannels: derivation.channelLayout.liveChannelPlan.managedChannels,
        )
        score = try MidiWriter.write(midi)
        metronome = try MidiWriter.write(MetronomeSequenceBuilder.metronomeOnlySequence(
            rendered: rendered, metronomeBeats: derivation.metronomeBeats,
        ))
    }
}
