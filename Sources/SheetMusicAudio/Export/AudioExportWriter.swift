// swiftlint:disable file_length
// Three writer classes (PCM, Compressed, MP3) live here by design;
// splitting would weaken cohesion without reducing per-reader complexity.
import AVFoundation
import Foundation

/// Internal protocol. Hides the AVAudioFile / AVAssetWriter choice
/// from `AudioFileExporter`'s render loop.
///
/// All writers consume float32, non-interleaved `AVAudioPCMBuffer`s
/// at the output sample rate. They internally convert / encode as
/// needed for the destination format.
protocol AudioExportWriter {
    func write(_ buffer: AVAudioPCMBuffer) async throws
    func finish() async throws
}

/// `AVAudioFile`-backed writer used for WAV and AIFF.
///
/// AVAudioFile infers the file container from the URL's extension.
/// We pick `.aifc` for AIFF when the user requested float32 PCM
/// (the AIFF spec is integer-only; AIFC is its float-capable
/// cousin); for int variants we stay on `.aiff`.
///
/// Implemented as a `final class` so that `finish()` can release
/// the underlying `AVAudioFile` (which flushes and closes on
/// deallocation) while the caller still holds a reference to the
/// writer.
final class PCMAudioExportWriter: AudioExportWriter {
    private var file: AVAudioFile?

    init(url: URL, format: AudioFileFormat) throws {
        let options: PCMOptions
        switch format {
        case let .wav(o): options = o
        case let .aiff(o): options = o
        default:
            throw AudioExportError.engineSetupFailed(
                underlying: "PCMAudioExportWriter requires .wav or .aiff",
            )
        }
        let resolvedURL = Self.resolveURL(url, for: format, bitDepth: options.bitDepth)

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels.rawValue,
        ]
        switch options.bitDepth {
        case .int16:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        case .int24:
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
        case .int32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = false
        case .float32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        }
        settings[AVLinearPCMIsBigEndianKey] = (resolvedURL.pathExtension.lowercased() == "aiff")

        do {
            file = try AVAudioFile(
                forWriting: resolvedURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false,
            )
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    /// Float32 PCM in AIFF requires the .aifc extension. Caller
    /// passes a `.aiff` URL; we rewrite to `.aifc` for the float
    /// row.
    private static func resolveURL(
        _ url: URL, for format: AudioFileFormat, bitDepth: PCMBitDepth,
    ) -> URL {
        if case .aiff = format, bitDepth == .float32 {
            return url.deletingPathExtension().appendingPathExtension("aifc")
        }
        return url
    }

    func write(_ buffer: AVAudioPCMBuffer) async throws {
        guard let file else {
            throw AudioExportError.fileWriteFailed(underlying: "writer already finished")
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    func finish() async throws {
        // Setting file to nil triggers AVAudioFile.deinit, which
        // flushes all pending writes and closes the file handle.
        file = nil
    }
}

/// `AVAudioFile`-backed writer for AAC (M4A).
///
/// Implemented as a `final class` for the same reason as
/// `PCMAudioExportWriter`: `finish()` needs to release the underlying
/// `AVAudioFile` so it flushes and closes before callers read the
/// file back.
final class CompressedAudioExportWriter: AudioExportWriter {
    private var file: AVAudioFile?

    init(url: URL, format: AudioFileFormat) throws {
        let options: CompressedOptions
        switch format {
        case let .m4a(o): options = o
        default:
            throw AudioExportError.engineSetupFailed(
                underlying: "CompressedAudioExportWriter requires .m4a",
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels.rawValue,
            AVEncoderBitRateKey: options.bitRate,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false,
            )
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) async throws {
        guard let file else {
            throw AudioExportError.fileWriteFailed(underlying: "writer already finished")
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    func finish() async throws {
        // Releasing the AVAudioFile reference triggers deinit, which
        // flushes and closes the file handle.
        file = nil
    }
}

/// `AVAssetWriter`-backed MP3 writer. Gated on iOS 17 / macOS 14 /
/// tvOS 17 / watchOS 10 — earlier OSes have no MP3 *write* path
/// in `AVAssetWriter`.
///
/// Note: although the `@available` gate includes macOS 14, `AVAssetWriter`
/// does not support the `.mp3` file type on macOS at runtime. On macOS this
/// init throws `AudioExportError.formatUnsupportedOnThisOS`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class MP3AudioExportWriter: AudioExportWriter, @unchecked Sendable {
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private var startedSession = false
    private var presentationFrames: Int64 = 0
    private let sampleRate: Double

    /// Validates the format and builds the initialized (assetWriter, input, sampleRate)
    /// triple — or throws before any stored-property initialization is needed.
    private static func makeComponents(
        url: URL, format: AudioFileFormat,
    ) throws -> (AVAssetWriter, AVAssetWriterInput, Double) {
        let options: CompressedOptions
        switch format {
        case let .mp3(o): options = o
        default:
            throw AudioExportError.engineSetupFailed(
                underlying: "MP3AudioExportWriter requires .mp3",
            )
        }
        // AVAssetWriter does not support .mp3 on macOS — only on iOS/tvOS.
        // Guard here so init can still initialize all stored lets on every
        // platform (Swift's definitive-initialization rules require it).
        #if os(macOS)
            throw AudioExportError.formatUnsupportedOnThisOS(format)
        #else
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: url, fileType: .mp3)
            } catch {
                throw AudioExportError.fileWriteFailed(
                    underlying: (error as NSError).localizedDescription,
                )
            }
            let inputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEGLayer3,
                AVSampleRateKey: options.sampleRate,
                AVNumberOfChannelsKey: options.channels.rawValue,
                AVEncoderBitRateKey: options.bitRate,
            ]
            let writerInput = AVAssetWriterInput(
                mediaType: .audio, outputSettings: inputSettings,
            )
            writerInput.expectsMediaDataInRealTime = false
            writer.add(writerInput)

            guard writer.startWriting() else {
                throw AudioExportError.fileWriteFailed(
                    underlying: writer.error?.localizedDescription
                        ?? "AVAssetWriter.startWriting returned false",
                )
            }
            return (writer, writerInput, options.sampleRate)
        #endif
    }

    init(url: URL, format: AudioFileFormat) throws {
        let (writer, writerInput, rate) = try Self.makeComponents(url: url, format: format)
        assetWriter = writer
        input = writerInput
        sampleRate = rate
    }

    func write(_ buffer: AVAudioPCMBuffer) async throws {
        guard let sampleBuffer = try? makeCMSampleBuffer(
            from: buffer, pts: presentationFrames,
        ) else {
            throw AudioExportError.fileWriteFailed(
                underlying: "Could not wrap PCM buffer as CMSampleBuffer",
            )
        }
        if !startedSession {
            assetWriter.startSession(
                atSourceTime: CMTime(value: 0, timescale: CMTimeScale(sampleRate)),
            )
            startedSession = true
        }
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard input.append(sampleBuffer) else {
            throw AudioExportError.fileWriteFailed(
                underlying: assetWriter.error?.localizedDescription
                    ?? "AVAssetWriterInput.append returned false",
            )
        }
        presentationFrames += Int64(buffer.frameLength)
    }

    func finish() async throws {
        input.markAsFinished()
        await assetWriter.finishWriting()
        if assetWriter.status == .failed {
            throw AudioExportError.fileWriteFailed(
                underlying: assetWriter.error?.localizedDescription
                    ?? "AVAssetWriter.finishWriting reported failure",
            )
        }
    }

    private func makeCMSampleBuffer(
        from buffer: AVAudioPCMBuffer, pts: Int64,
    ) throws -> CMSampleBuffer {
        var asbd = buffer.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc,
        )
        guard status == noErr, let fmt = formatDesc else {
            throw AudioExportError.fileWriteFailed(
                underlying: "CMAudioFormatDescriptionCreate failed (\(status))",
            )
        }
        var sb: CMSampleBuffer?
        let ptsTime = CMTime(value: pts, timescale: CMTimeScale(sampleRate))
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [
                CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                    presentationTimeStamp: ptsTime,
                    decodeTimeStamp: .invalid,
                ),
            ],
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb,
        )
        guard status == noErr, let sb else {
            throw AudioExportError.fileWriteFailed(
                underlying: "CMSampleBufferCreate failed (\(status))",
            )
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList,
        )
        guard status == noErr else {
            throw AudioExportError.fileWriteFailed(
                underlying: "CMSampleBufferSetDataBuffer failed (\(status))",
            )
        }
        return sb
    }
}
