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
    /// metronome on/off, and the current playback rate. The
    /// implementation builds a *dedicated* `AVAudioEngine` per
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
        let framesToRender = AVAudioFrameCount(
            (durationSec * outputFormat.sampleRate).rounded(.up),
        )
        let writer = try AudioFileExporter.makeWriter(url: url, format: format)
        let exporter = AudioFileExporter()
        let snapshot = exportEngineSnapshot()

        setStateForExport(.exporting)
        do {
            let pipeline = try Self.buildExportPipeline(
                score: score,
                snapshot: snapshot,
                outputFormat: outputFormat,
            )
            // Position the sequencer at `startTick` (in beats) so
            // partial-range exports start at the right place.
            let beatsPerTick = 1.0 / Double(timeline.division)
            pipeline.sequencer.currentPositionInBeats =
                Double(startTick) * beatsPerTick
            pipeline.sequencer.prepareToPlay()
            // Re-assert pitch-bend sensitivity right before the
            // sequencer starts — see the matching block in
            // `PlaybackEngine.play(from:in:)` for the rationale.
            for instrument in pipeline.samplers {
                for ch: UInt8 in 0 ..< 16 where ch != 9 {
                    MIDISynthBuilder.setPitchBendSensitivity(
                        into: instrument, semitones: 12, onChannel: ch,
                    )
                }
            }
            try pipeline.sequencer.start()

            try await exporter.renderLoop(
                engine: pipeline.engine,
                outputFormat: outputFormat,
                framesToRender: framesToRender,
                writer: writer,
                progress: progress,
            )
            Self.teardown(pipeline: pipeline)
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

    /// Build a dedicated `AVAudioEngine` + a multi-timbral AUMIDISynth
    /// + a loaded `AVAudioSequencer` ready to drive an offline render
    /// of `score`. Mirrors the live engine: full GM SoundFont loaded
    /// once into one synth, every staff addressed by its
    /// renderer-assigned MIDI channel.
    ///
    /// The engine is left in manual-rendering mode and started so the
    /// caller can immediately call `renderLoop`. Caller owns the
    /// returned pipeline and must call `teardown(pipeline:)` before
    /// releasing.
    private static func buildExportPipeline(
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
    ) throws -> ExportPipeline {
        let engine = AVAudioEngine()
        let resolver = snapshot.resolver

        // Gain-limiter output chain — mirrors the live engine's master
        // chain (PlaybackEngine.buildMasterChain). Rebuilt here so
        // exported files reflect the chosen master gain.
        let (scoreGainMixer, sumMixer) = buildOutputChain(
            engine: engine, gain: snapshot.masterGain,
        )

        // 1. Build the score synth (routed through the master stage).
        let exportSynth = buildScoreSynth(
            score: score, snapshot: snapshot, resolver: resolver,
            engine: engine, output: scoreGainMixer,
        )
        let soloedExists = snapshot.mixerChannels.contains { $0.isSoloed }
        applyMixerSnapshot(
            scoreSynth: exportSynth,
            channels: snapshot.mixerChannels,
            soloedExists: soloedExists,
        )

        // 2. Optional metronome synth / track.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, engine: engine, output: sumMixer,
        )

        // 3. Render MIDI bytes (score tracks + optional metronome
        //    track) and load into a fresh sequencer bound to the
        //    fresh engine.
        var midi = try MidiRenderer.render(score: score)
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
            mixerManagedChannels: Set(exportSynth.staffChannels.values.map(Int.init)),
        )
        let bytes = try MidiWriter.write(midi)
        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: bytes, options: [])
        let staffTrackCount = score.allStaves.count
        for (i, track) in sequencer.tracks.enumerated() {
            if i < staffTrackCount {
                track.destinationAudioUnit = exportSynth.staffIsDrum[i] == true
                    ? exportSynth.percussion
                    : exportSynth.melodic
            } else if let s = metronomeSampler {
                track.destinationAudioUnit = s
            }
        }
        sequencer.rate = snapshot.rate

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
            sequencer: sequencer,
            samplers: [exportSynth.melodic, exportSynth.percussion],
            metronomeSampler: metronomeSampler,
        )
    }

    /// Attach the gain-limiter output chain
    /// (scoreGainMixer → sumMixer → PeakLimiter → mainMixerNode) to
    /// `engine` and seed `scoreGainMixer.outputVolume` with `gain`.
    /// Returns `(scoreGainMixer, sumMixer)` so callers can route the
    /// score synth and metronome sampler through the same chain.
    /// Mirrors `PlaybackEngine.buildMasterChain` from `+Master.swift`.
    private static func buildOutputChain(
        engine: AVAudioEngine,
        gain: Float,
    ) -> (scoreGainMixer: AVAudioMixerNode, sumMixer: AVAudioMixerNode) {
        let scoreGainMixer = AVAudioMixerNode()
        let sumMixer = AVAudioMixerNode()
        let limiter = makePeakLimiter()
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(limiter)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = gain
        return (scoreGainMixer, sumMixer)
    }

    private struct ScoreSynth {
        let melodic: AVAudioUnitMIDIInstrument
        let percussion: AVAudioUnitMIDIInstrument
        let staffChannels: [Int: UInt8]
        /// Flat staff index → is-drum, for per-track routing + mixer dispatch.
        let staffIsDrum: [Int: Bool]
    }

    private static func buildScoreSynth(
        score: Score,
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

        let percussion = MIDISynthBuilder.make()
        engine.attach(percussion)
        engine.connect(percussion, to: output, format: nil)
        if let url = resolver.defaultGMSoundfontURL {
            try? MIDISynthBuilder.loadSoundFont(
                into: percussion, url: url,
                bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
            )
        }

        // The SMF's tick-0 programChange events on each track set up
        // every channel's preset; pre-engine sendProgramChange is only
        // needed for mixer overrides that should win on the primary
        // channel of each staff.
        let perStaffChan = MidiRenderer.staffChannels(score: score)
        var staffChannels: [Int: UInt8] = [:]
        var staffIsDrum: [Int: Bool] = [:]
        for (idx, entry) in score.allStaves.enumerated() {
            let midiCh = UInt8(
                clamping: idx < perStaffChan.count
                    ? perStaffChan[idx] : 0,
            )
            staffChannels[idx] = midiCh
            staffIsDrum[idx] = score.part(at: entry.address)?
                .instrument.useDrumset == true
            if midiCh != 9,
               let chan = snapshot.mixerChannels.first(
                   where: { $0.id == .staff(idx) },
               ), let p = chan.program
            {
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
        }
        return ScoreSynth(
            melodic: melodic, percussion: percussion,
            staffChannels: staffChannels, staffIsDrum: staffIsDrum,
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
    /// synth's per-channel CC 7 state. Effective audibility mirrors
    /// the live mixer rules: if any channel is soloed, only soloed
    /// channels are audible; otherwise muted channels are silenced.
    private static func applyMixerSnapshot(
        scoreSynth: ScoreSynth,
        channels: [MixerChannel],
        soloedExists: Bool,
    ) {
        for chan in channels {
            guard case let .staff(idx) = chan.id,
                  let midiCh = scoreSynth.staffChannels[idx]
            else { continue }
            let unit = scoreSynth.staffIsDrum[idx] == true
                ? scoreSynth.percussion : scoreSynth.melodic
            let audible = soloedExists ? chan.isSoloed : !chan.isMuted
            let gain = audible ? chan.volume : 0
            let cc7 = UInt8(clamping: Int((gain * 127).rounded()))
            MIDISynthBuilder.sendControlChange(
                into: unit, controller: 7, value: cc7, onChannel: midiCh,
            )
        }
    }

    private static func teardown(pipeline: ExportPipeline) {
        pipeline.sequencer.stop()
        pipeline.engine.stop()
        pipeline.engine.disableManualRenderingMode()
        // Releasing the references is enough; AVAudioEngine cleans
        // up its attached nodes on dealloc.
    }

    private struct ExportPipeline {
        let engine: AVAudioEngine
        let sequencer: AVAudioSequencer
        let samplers: [AVAudioUnitMIDIInstrument]
        let metronomeSampler: AVAudioUnitMIDIInstrument?
    }
}
