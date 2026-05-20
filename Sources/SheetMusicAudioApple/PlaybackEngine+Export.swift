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

        let (startTick, endTick) = try Self.resolveRange(
            range, timeline: timeline, loop: loopRange,
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

        // 1. Build the score synth.
        let exportSynth = buildScoreSynth(
            score: score, snapshot: snapshot, resolver: resolver,
            engine: engine,
        )
        let soloedExists = snapshot.mixerChannels.contains { $0.isSoloed }
        applyMixerSnapshot(
            synth: exportSynth.synth,
            channels: snapshot.mixerChannels,
            staffChannels: exportSynth.staffChannels,
            soloedExists: soloedExists,
        )

        // 2. Optional metronome synth / track.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, resolver: resolver, engine: engine,
        )

        // 3. Render MIDI bytes (score tracks + optional metronome
        //    track) and load into a fresh sequencer bound to the
        //    fresh engine.
        var midi = try MidiRenderer.render(score: score)
        if metronomeSampler != nil {
            let metronome = MetronomeController(engine: engine)
            midi.tracks.append(metronome.metronomeTrack(
                beats: snapshot.metronomeBeats, division: midi.division,
            ))
        }
        // Strip RAC + complete RPN Data-Entry pair — see
        // `PlaybackEngine.postProcessForMIDISynth` for rationale.
        postProcessForMIDISynth(midi: &midi)
        let bytes = try MidiWriter.write(midi)
        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: bytes, options: [])
        let staffTrackCount = score.allStaves.count
        for (i, track) in sequencer.tracks.enumerated() {
            if i < staffTrackCount {
                track.destinationAudioUnit = exportSynth.synth
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
            samplers: [exportSynth.synth],
            metronomeSampler: metronomeSampler,
        )
    }

    private struct ScoreSynth {
        let synth: AVAudioUnitMIDIInstrument
        let staffChannels: [Int: UInt8]
    }

    private static func buildScoreSynth(
        score: Score,
        snapshot: ExportEngineSnapshot,
        resolver: SoundfontResolver,
        engine: AVAudioEngine,
    ) -> ScoreSynth {
        let instrument = MIDISynthBuilder.make()
        engine.attach(instrument)
        engine.connect(
            instrument, to: engine.mainMixerNode, format: nil,
        )
        if let url = resolver.defaultGMSoundfontURL {
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
        // The SMF's tick-0 programChange events on each track set up
        // every channel's preset; pre-engine sendProgramChange is only
        // needed for mixer overrides that should win on the primary
        // channel of each staff.
        let perStaffChan = MidiRenderer.staffChannels(score: score)
        var staffChannels: [Int: UInt8] = [:]
        for idx in score.allStaves.indices {
            let midiCh = UInt8(
                clamping: idx < perStaffChan.count
                    ? perStaffChan[idx] : 0,
            )
            staffChannels[idx] = midiCh
            if midiCh != 9,
               let chan = snapshot.mixerChannels.first(
                   where: { $0.id == .staff(idx) },
               ), let p = chan.program
            {
                // See PlaybackEngine.loadProgram — preload to load
                // the preset, then plain PC to select.
                MIDISynthBuilder.preloadPreset(
                    into: instrument,
                    bankMSB: 0, bankLSB: 0, program: p,
                    onChannel: midiCh,
                )
                let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
                _ = MusicDeviceMIDIEvent(
                    instrument.audioUnit, pcStatus, UInt32(p), 0, 0,
                )
            }
        }
        return ScoreSynth(
            synth: instrument, staffChannels: staffChannels,
        )
    }

    private static func buildMetronomeSampler(
        snapshot: ExportEngineSnapshot,
        resolver: SoundfontResolver,
        engine: AVAudioEngine,
    ) -> AVAudioUnitMIDIInstrument? {
        guard snapshot.metronomeEnabled,
              let metroURL = resolver.soundfontURL(
                  forBank: 0, program: 0, isDrums: true,
              ) ?? resolver.defaultGMSoundfontURL
        else { return nil }
        let s = MIDISynthBuilder.make()
        engine.attach(s)
        engine.connect(s, to: engine.mainMixerNode, format: nil)
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
        synth: AVAudioUnitMIDIInstrument,
        channels: [MixerChannel],
        staffChannels: [Int: UInt8],
        soloedExists: Bool,
    ) {
        for chan in channels {
            guard case let .staff(idx) = chan.id,
                  let midiCh = staffChannels[idx]
            else { continue }
            let audible = soloedExists ? chan.isSoloed : !chan.isMuted
            let gain = audible ? chan.volume : 0
            let cc7 = UInt8(clamping: Int((gain * 127).rounded()))
            MIDISynthBuilder.sendControlChange(
                into: synth, controller: 7, value: cc7, onChannel: midiCh,
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

    private static func resolveRange(
        _ range: AudioExportRange,
        timeline: PlaybackTimeline,
        loop: LoopRange?,
    ) throws -> (Int, Int) {
        switch range {
        case .full:
            return (0, timeline.totalTicks)
        case .currentLoop:
            if let loop {
                return (loop.startTick, loop.endTick)
            }
            return (0, timeline.totalTicks)
        case let .region(from, to):
            guard let sTick = resolveCursorTick(from, in: timeline),
                  let eTick = resolveCursorTick(to, in: timeline),
                  sTick < eTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (sTick, eTick)
        case let .regionThroughEnd(from, last):
            guard let sTick = resolveCursorTick(from, in: timeline),
                  let endTick = timeline.itemEndTicks[last],
                  sTick < endTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (sTick, endTick)
        }
    }

    /// Resolve a `ScoreCursor` to a timeline tick, with fallback for
    /// `.beat` cursors whose tick is occupied by a chord/rest frame
    /// (and therefore has no dedicated `.beat` frame).
    private static func resolveCursorTick(
        _ cursor: ScoreCursor,
        in timeline: PlaybackTimeline,
    ) -> Int? {
        if let frame = timeline.frame(forCursor: cursor) {
            return frame.tick
        }
        guard case let .beat(measureIndex: mi, tickInMeasure: tim) = cursor else {
            return nil
        }
        for frame in timeline.frames {
            if case let .beat(measureIndex: fmi, tickInMeasure: ftim) = frame.cursor,
               fmi == mi
            {
                let measureStart = frame.tick - ftim
                let absoluteTick = measureStart + tim
                if absoluteTick >= 0, absoluteTick <= timeline.totalTicks {
                    return absoluteTick
                }
            }
        }
        var measureStartTick: Int?
        for (id, tick) in timeline.itemTicks {
            guard id.measureIndex == mi else { continue }
            if let existing = measureStartTick {
                measureStartTick = min(existing, tick)
            } else {
                measureStartTick = tick
            }
        }
        if let start = measureStartTick {
            let absoluteTick = start + tim
            if absoluteTick >= 0, absoluteTick <= timeline.totalTicks {
                return absoluteTick
            }
        }
        return nil
    }
}
