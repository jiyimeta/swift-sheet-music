import AVFoundation
import Foundation
import SheetMusicAudioCore

/// Drives `AVAudioEngine` in offline manual rendering mode and
/// pumps each rendered buffer into an `AudioExportWriter`.
///
/// Owned and invoked by `PlaybackEngine.exportAudioFile(...)`. The
/// public surface is small on purpose; engine setup / teardown
/// stays in `PlaybackEngine+Export` so the lifecycle invariants
/// (manual mode toggle, sequencer rebuild, audio session) all live
/// next to the existing `prepare(score:)` code.
actor AudioFileExporter {
    /// Buffer size for each `engine.renderOffline(...)` pull. Apple
    /// docs recommend powers of two; 4096 is a sweet spot between
    /// allocation cost and progress-callback granularity.
    static let bufferFrames: AVAudioFrameCount = 4096

    /// Factory used by `PlaybackEngine+Export` and by tests. The MP3
    /// path is gated by OS *and* by platform — `AVAssetWriter` does
    /// not accept `fileType: .mp3` on macOS even on 14+, so we
    /// short-circuit there.
    static func makeWriter(
        url: URL, format: AudioFileFormat,
    ) throws -> any AudioExportWriter {
        switch format {
        case .wav, .aiff:
            return try PCMAudioExportWriter(url: url, format: format)
        case .m4a:
            return try CompressedAudioExportWriter(url: url, format: format)
        case .mp3:
            #if os(macOS)
                throw AudioExportError.formatUnsupportedOnThisOS(format)
            #else
                if #available(iOS 17, tvOS 17, watchOS 10, *) {
                    return try MP3AudioExportWriter(url: url, format: format)
                } else {
                    throw AudioExportError.formatUnsupportedOnThisOS(format)
                }
            #endif
        }
    }

    /// Resolve a format → output `AVAudioFormat` (always float32,
    /// non-interleaved) at the user-requested sample rate /
    /// channel count.
    static func outputFormat(for format: AudioFileFormat) -> AVAudioFormat {
        let rate: Double
        let channels: AudioChannelCount
        switch format {
        case let .wav(o):
            rate = o.sampleRate
            channels = o.channels
        case let .aiff(o):
            rate = o.sampleRate
            channels = o.channels
        case let .m4a(o):
            rate = o.sampleRate
            channels = o.channels
        case let .mp3(o):
            rate = o.sampleRate
            channels = o.channels
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: AVAudioChannelCount(channels.rawValue),
            interleaved: false,
        )! // swiftlint:disable:this force_unwrapping
    }

    /// Render `framesToRender` from `engine` (already in offline
    /// manual rendering mode) to `writer`, reporting progress
    /// via `progress` and honoring cancellation.
    ///
    /// `engine` and sequencer must already be primed by the
    /// caller. This method does NOT toggle manual rendering mode
    /// on/off — that's the caller's responsibility so it can keep
    /// teardown in lockstep with `PlaybackEngine` lifecycle.
    nonisolated func renderLoop(
        engine: AVAudioEngine,
        outputFormat: AVAudioFormat,
        framesToRender: AVAudioFrameCount,
        writer: any AudioExportWriter,
        progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: Self.bufferFrames,
        ) else {
            throw AudioExportError.engineSetupFailed(
                underlying: "Could not allocate AVAudioPCMBuffer",
            )
        }
        var framesWritten: AVAudioFrameCount = 0
        var lastProgressEmit = CFAbsoluteTimeGetCurrent()

        while framesWritten < framesToRender {
            try Task.checkCancellation()
            let remaining = framesToRender - framesWritten
            let request = min(Self.bufferFrames, remaining)
            buffer.frameLength = 0
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(request, to: buffer)
            } catch {
                throw AudioExportError.engineSetupFailed(
                    underlying: (error as NSError).localizedDescription,
                )
            }
            switch status {
            case .success, .insufficientDataFromInputNode:
                try await writer.write(buffer)
                framesWritten += buffer.frameLength
                let now = CFAbsoluteTimeGetCurrent()
                if let progress, now - lastProgressEmit > 0.033 {
                    let fraction = min(
                        1.0,
                        Double(framesWritten) / Double(framesToRender),
                    )
                    await MainActor.run { progress(fraction) }
                    lastProgressEmit = now
                }
            case .cannotDoInCurrentContext:
                try await Task.sleep(nanoseconds: 1_000_000)
            case .error:
                throw AudioExportError.engineSetupFailed(
                    underlying: "AVAudioEngine.renderOffline returned .error",
                )
            @unknown default:
                throw AudioExportError.engineSetupFailed(
                    underlying: "AVAudioEngine.renderOffline unknown status",
                )
            }
        }
        try await writer.finish()
        if let progress {
            await MainActor.run { progress(1.0) }
        }
    }
}
