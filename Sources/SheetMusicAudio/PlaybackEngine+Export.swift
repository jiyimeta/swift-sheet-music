@preconcurrency import AVFoundation
import Foundation
import SheetMusicCore
import SheetMusicMIDI

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension PlaybackEngine {
    /// Offline-render the prepared score to an audio file at `url`.
    ///
    /// The exported audio reflects the live engine state: mixer
    /// (volume / mute / solo), per-staff program changes,
    /// metronome on/off, and the current playback rate. While
    /// rendering, the engine is in manual rendering mode and
    /// `state == .exporting`; normal playback is suspended. On
    /// completion / failure / cancellation the engine is restored
    /// and `state` returns to `.stopped`.
    ///
    /// `prepare(score:)` must have been called for the same `score`
    /// instance; otherwise throws `.noScorePrepared`.
    ///
    /// On `Task.cancel()` the in-flight render is aborted at the
    /// next buffer boundary; the partial output file at `url` is
    /// deleted.
    public func exportAudioFile( // swiftlint:disable:this function_body_length
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

        setStateForExport(.exporting)
        let avEngine = exportEngine()
        let previouslyRunning = avEngine.isRunning
        exportSequencer()?.stop()
        // `enableManualRenderingMode` requires the engine to be stopped
        // first — it throws `AVAudioEngineManualRenderingErrorInitialized`
        // (-80801) when called on a running engine. Pause / stop here;
        // we restore to running on completion if it was running before.
        if avEngine.isRunning {
            avEngine.stop()
        }

        do {
            try avEngine.enableManualRenderingMode(
                .offline,
                format: outputFormat,
                maximumFrameCount: AudioFileExporter.bufferFrames,
            )
            try avEngine.start()

            try buildSequencerForExport(score: score)
            guard let sequencer = exportSequencer() else {
                throw AudioExportError.engineSetupFailed(
                    underlying: "Sequencer build failed",
                )
            }
            sequencer.currentPositionInBeats =
                Double(startTick) / Double(timeline.division)
            sequencer.prepareToPlay()
            try sequencer.start()

            try await exporter.renderLoop(
                engine: avEngine,
                outputFormat: outputFormat,
                framesToRender: framesToRender,
                writer: writer,
                progress: progress,
            )

            sequencer.stop()
            avEngine.stop()
            avEngine.disableManualRenderingMode()
            if previouslyRunning {
                try? avEngine.start()
            }
            setStateForExport(.stopped)
        } catch is CancellationError {
            await teardownAfterExportFailure(
                avEngine: avEngine, previouslyRunning: previouslyRunning,
                url: url,
            )
            throw AudioExportError.cancelled
        } catch let err as AudioExportError {
            await teardownAfterExportFailure(
                avEngine: avEngine, previouslyRunning: previouslyRunning,
                url: url,
            )
            throw err
        } catch {
            await teardownAfterExportFailure(
                avEngine: avEngine, previouslyRunning: previouslyRunning,
                url: url,
            )
            throw AudioExportError.engineSetupFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    private func teardownAfterExportFailure(
        avEngine: AVAudioEngine, previouslyRunning: Bool, url: URL,
    ) async {
        exportSequencer()?.stop()
        avEngine.stop()
        avEngine.disableManualRenderingMode()
        if previouslyRunning {
            try? avEngine.start()
        }
        try? FileManager.default.removeItem(at: url)
        setStateForExport(.stopped)
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
            // `frame(forCursor:)` finds `.beat` cursors by exact match,
            // but beat-cursor frames are only emitted for ticks that
            // carry no chord/rest onset. Fall back to `resolveCursorTick`
            // which computes the tick from the measure/beat position.
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
    ///
    /// For `.item` cursors, delegates to `PlaybackTimeline.frame(forCursor:)`.
    /// For `.beat(measureIndex: m, tickInMeasure: t)`, first tries to find
    /// a dedicated beat frame; falls back to inferring the measure-start
    /// tick from `itemTicks` (all items in the same measure share the same
    /// measure-start tick, offset by their rhythmic position within it).
    private static func resolveCursorTick(
        _ cursor: ScoreCursor,
        in timeline: PlaybackTimeline,
    ) -> Int? {
        // Fast path: the cursor has a dedicated frame.
        if let frame = timeline.frame(forCursor: cursor) {
            return frame.tick
        }
        // Fallback for .beat cursors: infer measure-start tick from
        // beat frames first, then from itemTicks if the measure is
        // fully occupied by chord/rest onsets.
        guard case let .beat(measureIndex: mi, tickInMeasure: tim) = cursor else {
            return nil
        }
        // Attempt 1: find any .beat frame in the same measure.
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
        // Attempt 2: the measure is fully occupied (no .beat frames).
        // Find the minimum onset tick of any item in this measure via
        // `itemTicks`. Since `tickInMeasure` is relative to the measure
        // start, the item with the earliest tick in the measure IS the
        // measure start when `tickInMeasure == 0`; for other values of
        // `tickInMeasure` we add the offset onto the inferred start.
        //
        // `ScoreItemID.measureIndex` exposes the measure index directly.
        var measureStartTick: Int?
        for (id, tick) in timeline.itemTicks {
            guard id.measureIndex == mi else { continue }
            // The earliest tick among items in this measure is the
            // measure start (beat 1 tick). All onsets are >= measureStart.
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
