import CMediaFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import Synchronization

// Audio-file export: the prepared score rendered as fast as FluidSynth computes, through the same render the device
// thread pulls, into a WAV, AIFF or AAC file (folino spec 2026-10-05-windows-phase4-import-export-pdf-design §8.2).

extension WindowsPlaybackEngine {
    /// Whether this engine can write `format` on this Windows: WAV and AIFF always, AAC (`.m4a`) when Media
    /// Foundation's encoder is installed and takes the options, MP3 never. What a host asks before it offers the
    /// format; cheap after the first ask.
    public static func canExport(_ format: AudioFileFormat) -> Bool {
        switch format {
        case .wav, .aiff: true
        case let .m4a(options): AudioFileSinks.aacAccepts(options) && aacEncoderAvailable
        case .mp3: false
        }
    }

    /// Asked of Media Foundation once: installing the Media Feature Pack takes a restart, so the answer holds for the
    /// process.
    private static let aacEncoderAvailable = cmf_aac_encoder_available() == 1

    /// Renders the prepared `score` to `url` with the engine's current mixer, tuning, transposition, rate, master gain
    /// and output stage — the Apple engine's `exportAudioFile`, with its errors (`AudioExportError`).
    ///
    /// An engine made `.offline` at the format's rate renders in place: its transport plays the range from its start
    /// and ends stopped at the top, its loop as it was. Any other engine renders through a twin (`exportTwin`), so a
    /// live engine keeps its position, loop and state. The loop is not played and there is no count-in. The file ends
    /// where the transport does — the end of the score, repeats included, or of the range — at chunk resolution. On
    /// cancellation or failure the partial file is deleted.
    ///
    /// Called from the engine's control thread like every other control call, and not while another export, a prepare
    /// or a teardown runs on the same engine.
    public func exportAudioFile(
        to url: URL, score: Score, format: AudioFileFormat, range: AudioExportRange = .full,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws {
        guard let loaded, loaded.score == score else { throw AudioExportError.noScorePrepared }
        guard Self.canExport(format) else { throw AudioExportError.formatUnsupportedOnThisOS(format) }
        // Resolved here, against this engine's loop: a twin has none.
        let ticks = try unrolledTicks(of: range, in: loaded)
        let sampleRate = Self.sampleRate(of: format)
        let renderer: WindowsPlaybackEngine
        if output == .offline(sampleRate: sampleRate) {
            renderer = self
        } else {
            renderer = try exportTwin(sampleRate: sampleRate)
        }
        defer {
            if renderer !== self {
                renderer.teardown()
            }
        }
        try await renderer.renderPrepared(to: url, format: format, ticks: ticks, progress: progress)
    }

    /// An `.offline` engine at `sampleRate` holding this engine's prepared score and what it plays it with — mixer,
    /// tuning, transposition, rate, master gain and output stage: the Apple engine's export snapshot. The SoundFont is
    /// loaded again on the twin.
    func exportTwin(sampleRate: Double) throws -> WindowsPlaybackEngine {
        guard let loaded else { throw AudioExportError.noScorePrepared }
        let twin = WindowsPlaybackEngine(
            soundfontResolver: resolver, metronomeClickProvider: metronomeClickProvider,
            output: .offline(sampleRate: sampleRate),
        )
        do {
            try twin.prepareFully(score: loaded.score, derivation: loaded.derivation, renderedMidi: loaded.rendered)
        } catch {
            twin.teardown()
            throw AudioExportError.engineSetupFailed(underlying: "\(error)")
        }
        let state = core.shared.withLock { shared in
            ExportState(
                mixerChannels: shared.mixerChannels, tuningCents: shared.tuningCents,
                transposeSemitones: shared.transposeSemitones, rate: shared.rate, outputGain: shared.outputGain,
                outputStage: shared.outputStage,
            )
        }
        twin.core.shared.withLock { shared in
            shared.mixerChannels = state.mixerChannels
            shared.tuningCents = state.tuningCents
            shared.transposeSemitones = state.transposeSemitones
            shared.outputGain = state.outputGain
            shared.outputStage = state.outputStage
            shared.applyTuning()
            shared.reassertChannelState()
            shared.applyMixerState()
        }
        twin.setRate(state.rate)
        return twin
    }

    private static func sampleRate(of format: AudioFileFormat) -> Double {
        switch format {
        case let .wav(options), let .aiff(options): options.sampleRate
        case let .m4a(options), let .mp3(options): options.sampleRate
        }
    }

    /// The range in unrolled ticks: the whole unrolled score for `.full` (and for `.currentLoop` with no loop), the
    /// first occurrence of each end otherwise — where `play(from:)` and the loop put them.
    private func unrolledTicks(of range: AudioExportRange, in loaded: LoadedScore) throws -> (start: Int, end: Int) {
        let total = core.shared.withLock { $0.totalTicks }
        let notated = try range.resolveTickRange(timeline: loaded.derivation.timeline, loop: loopRange)
        if notated.startTick == 0, notated.endTick >= loaded.derivation.timeline.totalTicks {
            return (0, total)
        }
        let unroll = loaded.derivation.unroll
        let start = unroll.firstUnrolledTick(forNotated: notated.startTick)
        let end = unroll.firstUnrolledTick(forNotated: notated.endTick)
        guard start < end else { throw AudioExportError.rangeNotInTimeline }
        return (start, end)
    }

    /// Plays `ticks` on this (offline) engine's transport and pulls it into a file on the export thread, then puts the
    /// transport back as a prepare leaves it, with the loop it had.
    private func renderPrepared(
        to url: URL, format: AudioFileFormat, ticks: (start: Int, end: Int), progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        let saved = core.shared.withLock { shared in
            let saved = (
                loopRange: shared.loopRange, transportLoop: shared.transportLoop, totalTicks: shared.totalTicks,
            )
            shared.stopPlayers(silence: .cut)
            shared.transportLoop = nil
            shared.loopRange = nil
            shared.rewind(to: ticks.start)
            // The stepper stops the transport at `totalTicks`: that is where a range ends.
            shared.totalTicks = ticks.end
            shared.startPlayers()
            shared.state = .playing
            shared.hasCursor = true
            shared.reassertPending = true
            return saved
        }
        let job = ExportJob(
            core: core, format: format, url: url, sampleRate: Self.sampleRate(of: format), ticks: ticks,
            progress: progress,
        )
        let result: Result<Void, any Error>
        do {
            try await withTaskCancellationHandler {
                try await job.run()
            } onCancel: {
                job.cancel()
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        stop()
        core.shared.withLock { shared in
            shared.totalTicks = saved.totalTicks
            shared.loopRange = saved.loopRange
            shared.transportLoop = saved.transportLoop
        }
        switch result {
        case .success:
            return
        case let .failure(error as AudioExportError):
            throw error
        case .failure(is CancellationError):
            throw AudioExportError.cancelled
        case let .failure(error):
            throw AudioExportError.fileWriteFailed(underlying: "\(error)")
        }
    }
}

/// What a twin takes from the engine it renders for.
private struct ExportState {
    let mixerChannels: [MixerChannel]
    let tuningCents: Double
    let transposeSemitones: Int
    let rate: Float
    let outputGain: Float
    let outputStage: MasterOutputStage
}

/// One export's file and render loop, on a thread of its own: the render is CPU-bound for as long as the score takes
/// to compute, which would hold a cooperative thread for minutes, and Media Foundation's writer belongs to the COM
/// apartment of the thread that opened it — so the file is opened, written, finished or abandoned and deleted all on
/// this one thread. Cancellation is a flag read before every chunk.
private final class ExportJob: @unchecked Sendable {
    /// 64 chunks handed to the sink at a time.
    static let blockFrames = PlaybackCore.chunkFrames * 64
    /// A transport that has not moved for this long, in rendered seconds, never will: the export stops rather than
    /// filling the disk.
    static let stallSeconds = 30.0

    private let core: PlaybackCore
    private let format: AudioFileFormat
    private let url: URL
    private let sampleRate: Double
    private let ticks: (start: Int, end: Int)
    private let progress: (@Sendable (Double) -> Void)?
    private let cancelled = Mutex(false)

    init(
        core: PlaybackCore, format: AudioFileFormat, url: URL, sampleRate: Double, ticks: (start: Int, end: Int),
        progress: (@Sendable (Double) -> Void)?,
    ) {
        self.core = core
        self.format = format
        self.url = url
        self.sampleRate = sampleRate
        self.ticks = ticks
        self.progress = progress
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let thread = Thread { [self] in
                continuation.resume(with: Result { try write() })
            }
            thread.name = "SheetMusicAudioWindows export"
            thread.start()
        }
    }

    /// The whole file, on the export thread: a failure or a cancel leaves no file behind.
    private func write() throws {
        try? FileManager.default.removeItem(at: url)
        let sink = try AudioFileSinks.make(format, at: url)
        do {
            try render(into: sink)
            try sink.finish()
        } catch {
            sink.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        progress?(1)
    }

    private func render(into sink: any AudioFileSink) throws {
        let chunk = PlaybackCore.chunkFrames
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.blockFrames * 2)
        defer { buffer.deallocate() }
        let clock = ContinuousClock()
        var lastReport = clock.now
        let stallFrames = Int(Self.stallSeconds * sampleRate)
        var lastTick = Int.min
        var framesSinceMove = 0
        var filled = 0
        var reachedEnd = false
        while !reachedEnd {
            if cancelled.withLock({ $0 }) {
                throw AudioExportError.cancelled
            }
            let pulled = core.renderOffline(into: buffer + filled * 2, frames: chunk)
            guard pulled.hasSession else {
                throw AudioExportError.engineSetupFailed(underlying: "the engine was torn down during the export")
            }
            filled += chunk
            reachedEnd = pulled.reachedEnd
            if pulled.tick != lastTick {
                lastTick = pulled.tick
                framesSinceMove = 0
            } else {
                framesSinceMove += chunk
                if framesSinceMove >= stallFrames {
                    throw AudioExportError.engineSetupFailed(underlying: "the transport stopped before the end")
                }
            }
            guard filled == Self.blockFrames || reachedEnd else { continue }
            try sink.append(UnsafeBufferPointer(start: buffer, count: filled * 2), frames: filled)
            filled = 0
            if let progress, !reachedEnd, clock.now - lastReport >= .milliseconds(33) {
                lastReport = clock.now
                let span = Double(max(1, ticks.end - ticks.start))
                progress(min(1, max(0, Double(pulled.tick - ticks.start) / span)))
            }
        }
    }
}
