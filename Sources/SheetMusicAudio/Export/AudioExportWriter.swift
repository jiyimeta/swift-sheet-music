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
