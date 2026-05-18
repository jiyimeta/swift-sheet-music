@preconcurrency import AVFoundation
import Foundation
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

    /// Build a dedicated `AVAudioEngine` + per-staff samplers + a
    /// loaded `AVAudioSequencer` ready to drive an offline render
    /// of `score`.
    ///
    /// The engine is left in manual-rendering mode and started so
    /// the caller can immediately call `renderLoop`. Caller owns
    /// the returned pipeline and must call `teardown(pipeline:)`
    /// before releasing.
    private static func buildExportPipeline( // swiftlint:disable:this function_body_length
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
    ) throws -> ExportPipeline {
        let engine = AVAudioEngine()
        let resolver = snapshot.resolver

        // 1. Build per-staff samplers, load the SF2 preset, apply
        //    snapshot mixer values (volume / mute / solo).
        let soloedExists = snapshot.mixerChannels.contains { $0.isSoloed }
        var samplers: [Int: AVAudioUnitSampler] = [:]

        for (idx, entry) in score.allStaves.enumerated() {
            let part = score.part(at: entry.address)
            let channel = part?.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part?.instrument.useDrumset == true
            let bank = UInt8(clamping: channel.bank)
            // Mixer can override the program (the live engine's
            // `loadProgram(forStaff:program:)` path) so prefer the
            // snapshot value when present.
            let program: UInt8
            if let chan = snapshot.mixerChannels.first(
                where: { $0.id == .staff(idx) },
            ), let p = chan.program {
                program = p
            } else {
                program = UInt8(clamping: channel.program)
            }
            let url = resolver.soundfontURL(
                forBank: bank, program: program, isDrums: isDrums,
            )
                ?? resolver.defaultGMSoundfontURL

            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            if let url {
                let bankMSB: UInt8 = isDrums
                    ? UInt8(kAUSampler_DefaultPercussionBankMSB)
                    : UInt8(kAUSampler_DefaultMelodicBankMSB)
                try? sampler.loadSoundBankInstrument(
                    at: url, program: program,
                    bankMSB: bankMSB, bankLSB: bank,
                )
            }
            samplers[idx] = sampler
        }

        applyMixerSnapshot(
            samplers: samplers, channels: snapshot.mixerChannels,
            soloedExists: soloedExists,
        )

        // 2. Optional metronome sampler / track.
        let metronomeSampler: AVAudioUnitSampler?
        if snapshot.metronomeEnabled,
           let metroURL = resolver.soundfontURL(
               forBank: 0, program: 0, isDrums: true,
           ) ?? resolver.defaultGMSoundfontURL
        {
            let s = AVAudioUnitSampler()
            engine.attach(s)
            engine.connect(s, to: engine.mainMixerNode, format: nil)
            try? s.loadSoundBankInstrument(
                at: metroURL, program: 0,
                bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0,
            )
            s.volume = snapshot.metronomeVolume
            metronomeSampler = s
        } else {
            metronomeSampler = nil
        }

        // 3. Render MIDI bytes (score tracks + optional metronome
        //    track) and load into a fresh sequencer bound to the
        //    fresh engine.
        var midi = try MidiRenderer.render(score: score)
        if metronomeSampler != nil {
            // Re-use `MetronomeController.metronomeTrack` so the beat
            // event shape stays consistent with live playback.
            let metronome = MetronomeController(engine: engine)
            midi.tracks.append(metronome.metronomeTrack(
                beats: snapshot.metronomeBeats, division: midi.division,
            ))
        }
        let bytes = try MidiWriter.write(midi)
        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: bytes, options: [])
        // Route staff tracks to their samplers; the metronome track
        // (appended last) routes to `metronomeSampler` if present.
        let staffTrackCount = samplers.count
        for (i, track) in sequencer.tracks.enumerated() {
            if i < staffTrackCount, let sampler = samplers[i] {
                track.destinationAudioUnit = sampler
            } else if i >= staffTrackCount, let s = metronomeSampler {
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
            samplers: Array(samplers.values),
            metronomeSampler: metronomeSampler,
        )
    }

    private static func applyMixerSnapshot(
        samplers: [Int: AVAudioUnitSampler],
        channels: [MixerChannel],
        soloedExists: Bool,
    ) {
        for chan in channels {
            guard case let .staff(idx) = chan.id,
                  let sampler = samplers[idx] else { continue }
            // Effective audibility mirrors the live mixer rules: if
            // any channel is soloed, only soloed channels are audible;
            // otherwise muted channels are silenced.
            let audible = soloedExists ? chan.isSoloed : !chan.isMuted
            sampler.volume = audible ? chan.volume : 0
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
        let samplers: [AVAudioUnitSampler]
        let metronomeSampler: AVAudioUnitSampler?
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
