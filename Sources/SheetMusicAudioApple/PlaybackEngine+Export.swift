// swiftlint:disable file_length
@preconcurrency import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

extension PlaybackEngine {
    /// Offline-render the prepared score to an audio file at `url`.
    ///
    /// The exported audio reflects the live engine state: mixer
    /// (volume / mute / solo), per-staff program changes,
    /// metronome on/off, and the current playback rate.
    ///
    /// It also reflects the live *synth*: when a `SynthBackend` is
    /// injected and can build an offline instance of itself
    /// (`makeOfflineInstance`), the export renders through that —
    /// so an export sounds like what the user just heard. Without
    /// one it falls back to the built-in AUMIDISynth pipeline,
    /// which steals voices on dense scores and sits at a different
    /// level. See `PlaybackEngine+ExportBackend`.
    ///
    /// The implementation builds a *dedicated* `AVAudioEngine` per
    /// export call rather than reusing the live playback engine —
    /// `AVAudioEngine.enableManualRenderingMode` is a global
    /// per-engine flag that doesn't compose with concurrent
    /// hardware-routed playback. The live samplers' SF2 patches
    /// are also fragile across manual-mode toggles in practice
    /// (the samplers sometimes revert to the default sine-wave
    /// preset), which is the second motivation for the fresh
    /// engine. Live mutable state (mixer levels, metronome on/off,
    /// playback rate) is snapshotted at the start of the call and
    /// reproduced on the export engine.
    ///
    /// `prepare(score:)` must have been called for the same `score`
    /// instance; otherwise throws `.noScorePrepared`.
    ///
    /// On `Task.cancel()` the in-flight render is aborted at the
    /// next buffer boundary; the partial output file at `url` is
    /// deleted.
    public func exportAudioFile(
        to url: URL,
        score: Score,
        format: AudioFileFormat,
        range: AudioExportRange = .full,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws {
        guard let timeline = exportTimeline() else {
            throw AudioExportError.noScorePrepared
        }

        let (startTick, endTick) = try range.resolveTickRange(
            timeline: timeline, loop: loopRange,
        )
        let startSec = timeline.frame(atTick: startTick)?.timeSeconds ?? 0
        let endSec = timeline.frame(atTick: endTick)?.timeSeconds
            ?? timeline.totalSeconds
        let durationSec = max(0, endSec - startSec)

        let outputFormat = AudioFileExporter.outputFormat(for: format)
        let snapshot = exportEngineSnapshot()
        // `durationSec` is timeline-seconds at rate 1.0, but the export
        // sequencer runs at `snapshot.rate` (`sequencer.rate =
        // snapshot.rate` below), so a rate < 1 (slow-practice export)
        // needs MORE wall-clock frames, not `durationSec * sampleRate`
        // worth — otherwise the render loop stops before the slowed
        // piece has finished sounding.
        let framesToRender = Self.renderFrameCount(
            durationSec: durationSec, rate: snapshot.rate, sampleRate: outputFormat.sampleRate,
        )
        let writer = try AudioFileExporter.makeWriter(url: url, format: format)
        let exporter = AudioFileExporter()

        setStateForExport(.exporting)
        do {
            let pipeline = try await buildPipeline(
                score: score,
                snapshot: snapshot,
                outputFormat: outputFormat,
                timeline: timeline,
                startTick: startTick,
            )
            // Tear the pipeline down on the way out however this ends. A
            // cancelled export used to leave its engine running in manual
            // rendering mode until dealloc; on the backend path that engine
            // owns a synth holding a tens-of-MB SoundFont, so leaning on ARC
            // timing is no longer good enough.
            do {
                try pipeline.start()
                try await exporter.renderLoop(
                    engine: pipeline.engine,
                    outputFormat: outputFormat,
                    framesToRender: framesToRender,
                    writer: writer,
                    progress: progress,
                )
            } catch {
                pipeline.teardown()
                throw error
            }
            pipeline.teardown()
            setStateForExport(.stopped)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            setStateForExport(.stopped)
            throw AudioExportError.cancelled
        } catch let err as AudioExportError {
            try? FileManager.default.removeItem(at: url)
            setStateForExport(.stopped)
            throw err
        } catch {
            try? FileManager.default.removeItem(at: url)
            setStateForExport(.stopped)
            throw AudioExportError.engineSetupFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    /// Frame count for the offline render loop, rate-corrected: `durationSec`
    /// is timeline-seconds at rate 1.0, but the export sequencer plays at
    /// `rate` (`sequencer.rate = snapshot.rate`), so the render actually
    /// spans `durationSec / rate` wall-clock seconds. `rate` is floored to a
    /// small positive value so a stray `0` (or negative) can't produce an
    /// infinite or zero frame count. `internal` (not `private`) so tests can
    /// exercise the rate-correction math directly.
    static func renderFrameCount(
        durationSec: Double, rate: Float, sampleRate: Double,
    ) -> AVAudioFrameCount {
        let renderSeconds = durationSec / Double(max(rate, 0.01))
        return AVAudioFrameCount((renderSeconds * sampleRate).rounded(.up))
    }

    /// Choose the export pipeline. An injected `SynthBackend` that can build an
    /// offline instance of itself wins — that is the only way the exported file
    /// reproduces what live playback sounds like, in both voice allocation and
    /// level. Everything else falls back to the built-in AUMIDISynth pipeline.
    private func buildPipeline(
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
        timeline: PlaybackTimeline,
        startTick: Int,
    ) async throws -> ExportPipeline {
        if let offline = backend?.makeOfflineInstance(
            sampleRate: outputFormat.sampleRate,
        ) {
            return try await Self.buildBackendExportPipeline(
                score: score,
                snapshot: snapshot,
                outputFormat: outputFormat,
                timeline: timeline,
                startTick: startTick,
                backend: offline,
            )
        }
        return try Self.buildExportPipeline(
            score: score,
            snapshot: snapshot,
            outputFormat: outputFormat,
            timeline: timeline,
            startTick: startTick,
        )
    }

    /// Build a dedicated `AVAudioEngine` + melodic and percussion
    /// `AVAudioUnitMIDIInstrument` units + a loaded `AVAudioSequencer`
    /// ready to drive an offline render of `score`. Mirrors the live
    /// engine: melodic carries pitched channels (ch≠9), percussion
    /// carries GM channel 9; drum staves route to percussion.
    ///
    /// The engine is left in manual-rendering mode and started so the
    /// caller can immediately `start()` the returned pipeline and call
    /// `renderLoop`. Caller owns the returned pipeline and must call
    /// its `teardown` before releasing.
    private static func buildExportPipeline(
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
        timeline: PlaybackTimeline,
        startTick: Int,
    ) throws -> ExportPipeline {
        let engine = AVAudioEngine()
        let resolver = snapshot.resolver
        // Same LIVE single-port collapse the playback engine uses — one
        // strip per (part × distinct instrument) — so the offline
        // export addresses the same channels the mixer snapshot was
        // keyed against.
        let plan = LiveChannelPlan.build(score: score)

        // Master output chain — mirrors the live engine's
        // (PlaybackEngine.buildMasterChain). Rebuilt here so exported
        // files reflect the chosen master gain and shaping stage.
        let (scoreGainMixer, sumMixer) = buildOutputChain(
            engine: engine,
            gain: snapshot.masterGain,
            stage: snapshot.masterOutputStage,
        )

        // 1. Build the score synth (routed through the master stage).
        let exportSynth = buildScoreSynth(
            score: score, plan: plan, snapshot: snapshot, resolver: resolver,
            engine: engine, output: scoreGainMixer,
        )
        applyMixerSnapshot(
            scoreSynth: exportSynth, channels: snapshot.mixerChannels,
        )

        // 2. Optional metronome synth / track.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, engine: engine, output: sumMixer,
        )

        // 3. Render MIDI bytes (score tracks + optional metronome
        //    track) and load into a fresh sequencer bound to the
        //    fresh engine.
        let sequencer = try makeExportSequencer(
            score: score, plan: plan, snapshot: snapshot, engine: engine,
            sumMixer: sumMixer, exportSynth: exportSynth,
            metronomeSampler: metronomeSampler,
        )

        // 4. Switch to manual rendering mode and start. Engine is
        //    fresh so `enableManualRenderingMode` always succeeds.
        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: AudioFileExporter.bufferFrames,
        )
        try engine.start()

        return ExportPipeline(
            engine: engine,
            start: {
                try startSequencer(
                    sequencer, melodic: exportSynth.melodic,
                    timeline: timeline, startTick: startTick,
                )
            },
            teardown: {
                sequencer.stop()
                engine.stop()
                engine.disableManualRenderingMode()
                // Releasing the references is enough; AVAudioEngine cleans
                // up its attached nodes on dealloc.
            },
        )
    }

    /// Render `score` to an SMF, append the metronome track when one is being
    /// sounded, post-process it for AUMIDISynth, and load it into a fresh
    /// `AVAudioSequencer` bound to `engine` with each track routed to its
    /// melodic / percussion / metronome unit.
    private static func makeExportSequencer(
        score: Score,
        plan: LiveChannelPlan,
        snapshot: ExportEngineSnapshot,
        engine: AVAudioEngine,
        sumMixer: AVAudioMixerNode,
        exportSynth: ScoreSynth,
        metronomeSampler: AVAudioUnitMIDIInstrument?,
    ) throws -> AVAudioSequencer {
        var midi = try MidiRenderer.render(score: score)
        // Collapse the MuseScore-exact multi-port SMF onto the same
        // live single-port channel set `exportSynth` was built against
        // — BEFORE `postProcessForMIDISynth` below, which strips tick-0
        // events keyed on those live channel numbers. See
        // `PlaybackEngine.cachedRender` for the identical live-playback
        // ordering.
        MidiChannelRemap.apply(midi: &midi, plan: plan)
        if metronomeSampler != nil {
            // This controller is used only to generate the metronome
            // MIDI track; `prepare(soundfontURL:)` is never called on it,
            // so `output` is never connected. Pass `sumMixer` anyway (not
            // `mainMixerNode`) so that if a future change does call
            // `prepare`, the metronome stays inside the master stage
            // rather than silently bypassing the limiter.
            let metronome = MetronomeController(
                engine: engine, output: sumMixer,
            )
            midi.tracks.append(metronome.metronomeTrack(
                beats: snapshot.metronomeBeats, division: midi.division,
            ))
        }
        // Strip RAC + complete RPN Data-Entry pair, and drop CC 7 on the
        // mixer-managed channels so the export's `applyMixerSnapshot`
        // volume / mute / solo wins instead of the SMF's tick-0 CC 7 —
        // see `PlaybackEngine.postProcessForMIDISynth` for rationale.
        postProcessForMIDISynth(
            midi: &midi,
            mixerManagedChannels: plan.managedChannels,
        )
        let bytes = try MidiWriter.write(midi)
        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: bytes, options: [])
        let staffTrackCount = score.allStaves.count
        for (i, track) in sequencer.tracks.enumerated() {
            if i < staffTrackCount {
                track.destinationAudioUnit = exportSynth.staffIsDrum[i] == true
                    ? (exportSynth.percussion ?? exportSynth.melodic)
                    : exportSynth.melodic
            } else if let s = metronomeSampler {
                track.destinationAudioUnit = s
            }
        }
        sequencer.rate = snapshot.rate
        return sequencer
    }

    /// Position and start the export sequencer. Split out of
    /// `buildExportPipeline` only for length; the ordering — position, prime,
    /// re-assert pitch bend, start — is the contract and must not be shuffled.
    private static func startSequencer(
        _ sequencer: AVAudioSequencer,
        melodic: AVAudioUnitMIDIInstrument,
        timeline: PlaybackTimeline,
        startTick: Int,
    ) throws {
        // Position the sequencer at `startTick` (in beats) so
        // partial-range exports start at the right place.
        let beatsPerTick = 1.0 / Double(timeline.division)
        sequencer.currentPositionInBeats = Double(startTick) * beatsPerTick
        sequencer.prepareToPlay()
        // Re-assert pitch-bend sensitivity right before the sequencer
        // starts — see the matching block in `PlaybackEngine.play(from:in:)`
        // for the rationale. Melodic only: percussion (GM ch 9) never uses
        // pitch bend, mirroring the live engine's `play(from:in:)` path.
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: melodic, semitones: 12, onChannel: ch,
            )
        }
        try sequencer.start()
    }

    /// Attach the master output chain
    /// (scoreGainMixer → sumMixer → softClip → PeakLimiter →
    /// mainMixerNode) to `engine`, seed `scoreGainMixer.outputVolume`
    /// with `gain`, and bypass whichever shaping nodes `stage` does not
    /// select. Returns `(scoreGainMixer, sumMixer)` so callers can route
    /// the score synth and metronome sampler through the same chain.
    /// Mirrors `PlaybackEngine.buildMasterChain` from `+Master.swift`.
    /// `internal` (not `private`) so the backend pipeline in
    /// `PlaybackEngine+ExportBackend` builds the identical master stage.
    static func buildOutputChain(
        engine: AVAudioEngine,
        gain: Float,
        stage: MasterOutputStage,
    ) -> (scoreGainMixer: AVAudioMixerNode, sumMixer: AVAudioMixerNode) {
        let scoreGainMixer = AVAudioMixerNode()
        let sumMixer = AVAudioMixerNode()
        let softClip = SoftClipAudioUnit.makeNode()
        let limiter = makePeakLimiter()
        softClip.bypass = stage != .softClip
        limiter.bypass = stage != .peakLimiter
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(softClip)
        engine.attach(limiter)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: softClip, format: nil)
        engine.connect(softClip, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = gain
        return (scoreGainMixer, sumMixer)
    }

    private struct ScoreSynth {
        let melodic: AVAudioUnitMIDIInstrument
        /// Separate percussion unit (GM channel 9), built only when the score has a drum part — mirrors the live
        /// engine's lazy percussion unit so a drumless export doesn't load the SoundFont twice. `nil` ⇒ no drums.
        let percussion: AVAudioUnitMIDIInstrument?
        /// Flat staff index → is-drum, for per-track routing.
        let staffIsDrum: [Int: Bool]
        /// Live MIDI channel per mixer strip identity — one entry per
        /// (part × distinct instrument), mirroring
        /// `PlaybackEngine.instrumentMIDIChannels`.
        let instrumentMIDIChannels: [MixerChannel.Kind: UInt8]
    }

    private static func buildScoreSynth( // swiftlint:disable:this function_body_length
        score: Score,
        plan: LiveChannelPlan,
        snapshot: ExportEngineSnapshot,
        resolver: SoundfontResolver,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> ScoreSynth {
        let melodic = MIDISynthBuilder.make()
        engine.attach(melodic)
        engine.connect(melodic, to: output, format: nil)
        if let url = resolver.defaultGMSoundfontURL {
            try? MIDISynthBuilder.loadSoundFont(
                into: melodic, url: url,
                bankMSB: 0, bankLSB: 0, program: 0,
            )
        }
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: melodic, semitones: 12, onChannel: ch,
            )
        }

        // Percussion unit only when the score has a drum part (matches the live engine).
        var percussion: AVAudioUnitMIDIInstrument?
        if score.parts.contains(where: \.instrument.useDrumset) {
            let p = MIDISynthBuilder.make()
            engine.attach(p)
            engine.connect(p, to: output, format: nil)
            if let url = resolver.defaultGMSoundfontURL {
                try? MIDISynthBuilder.loadSoundFont(
                    into: p, url: url,
                    bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
                )
            }
            percussion = p
        }

        // Per-track routing picks the melodic or the percussion unit per
        // staff; the CHANNEL each event rides on is already baked into
        // the rendered SMF by `MidiChannelRemap`.
        var staffIsDrum: [Int: Bool] = [:]
        for (idx, entry) in score.allStaves.enumerated() {
            staffIsDrum[idx] = score.part(at: entry.address)?
                .instrument.useDrumset == true
        }

        // The SMF's tick-0 programChange events on each strip's channel
        // set up every channel's preset; pre-engine sendProgramChange is
        // only needed for mixer overrides. Cover EVERY deduped strip —
        // not just each staff's primary — so a part with an instrument
        // change doesn't leave its secondary instrument on program 0
        // (piano) for a range export that starts after that instrument's
        // own embedded programChange.
        var instrumentMIDIChannels: [MixerChannel.Kind: UInt8] = [:]
        for strip in plan.strips {
            let id = MixerChannel.Kind.instrument(
                partIndex: strip.partIndex, ordinal: strip.ordinal,
            )
            let midiCh = UInt8(clamping: strip.liveChannel)
            instrumentMIDIChannels[id] = midiCh
            guard midiCh != 9,
                  let chan = snapshot.mixerChannels.first(where: { $0.id == id }),
                  let p = chan.program
            else { continue }
            // See PlaybackEngine.loadProgram — preload to load
            // the preset, then plain PC to select.
            MIDISynthBuilder.preloadPreset(
                into: melodic,
                bankMSB: 0, bankLSB: 0, program: p,
                onChannel: midiCh,
            )
            let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
            _ = MusicDeviceMIDIEvent(
                melodic.audioUnit, pcStatus, UInt32(p), 0, 0,
            )
        }
        // Reproduce the live engine's transpose + master A4 tuning on the offline synths:
        // melodic = calibration + transpose (semitones→cents), percussion = calibration only.
        Self.applyMasterTuning(
            to: melodic,
            cents: snapshot.masterTuningCents + Double(snapshot.transposeSemitones) * 100,
        )
        if let percussion {
            Self.applyMasterTuning(to: percussion, cents: snapshot.masterTuningCents)
        }

        return ScoreSynth(
            melodic: melodic, percussion: percussion,
            staffIsDrum: staffIsDrum,
            instrumentMIDIChannels: instrumentMIDIChannels,
        )
    }

    private static func buildMetronomeSampler(
        snapshot: ExportEngineSnapshot,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> AVAudioUnitMIDIInstrument? {
        guard snapshot.metronomeEnabled,
              let metroURL = snapshot.metronomeSoundFontURL
        else { return nil }
        let s = MIDISynthBuilder.make()
        engine.attach(s)
        engine.connect(s, to: output, format: nil)
        try? MIDISynthBuilder.loadSoundFont(
            into: s, url: metroURL,
            bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
        )
        s.volume = snapshot.metronomeVolume
        return s
    }

    /// Push the mixer snapshot's volume / mute / solo onto the export
    /// synth's per-strip CC 7 state — every deduped (part × instrument)
    /// channel, not just each staff's primary. Effective audibility
    /// mirrors the live mixer rules: if any solo-bus channel is soloed,
    /// only soloed channels are audible; otherwise muted channels are
    /// silenced. "Any" is scoped to `MixerChannel.isSoloable` members —
    /// the metronome is off the solo bus, and whether the click renders
    /// is carried by the snapshot's own `metronomeEnabled`.
    private static func applyMixerSnapshot(
        scoreSynth: ScoreSynth,
        channels: [MixerChannel],
    ) {
        let soloedExists = channels.contains { $0.isSoloable && $0.isSoloed }
        for chan in channels {
            guard case .instrument = chan.id,
                  let midiCh = scoreSynth.instrumentMIDIChannels[chan.id]
            else { continue }
            let unit = midiCh == 9
                ? (scoreSynth.percussion ?? scoreSynth.melodic) : scoreSynth.melodic
            let audible = soloedExists ? chan.isSoloed : !chan.isMuted
            let gain = audible ? chan.volume : 0
            let cc7 = UInt8(clamping: Int((gain * 127).rounded()))
            MIDISynthBuilder.sendControlChange(
                into: unit, controller: 7, value: cc7, onChannel: midiCh,
            )
        }
    }

    /// One prepared offline render, independent of which synth drives it.
    ///
    /// `engine` is already in manual-rendering mode and started; `start` kicks
    /// whichever transport the pipeline owns (an `AVAudioSequencer` for the
    /// AUMIDISynth path, the backend's own for `+ExportBackend`) and must be
    /// called before pulling frames; `teardown` stops both and leaves manual
    /// rendering mode. Closures rather than stored transports because the two
    /// paths share no transport type.
    struct ExportPipeline {
        let engine: AVAudioEngine
        let start: @MainActor () throws -> Void
        let teardown: @MainActor () -> Void
    }
}
