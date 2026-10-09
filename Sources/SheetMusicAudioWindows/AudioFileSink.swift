import CMediaFoundation
import Foundation
import SheetMusicAudioCore

/// Where an export's rendered audio goes: interleaved stereo float in, the file's own format out. One sink per file,
/// used from the export thread alone. `finish` completes the file; `abandon` (also after a failed `finish`) lets go of
/// what the sink holds and leaves the caller to delete the file.
protocol AudioFileSink: AnyObject {
    func append(_ interleavedStereo: UnsafeBufferPointer<Float>, frames: Int) throws
    func finish() throws
    func abandon()
}

enum AudioFileSinks {
    /// What Microsoft's AAC encoder takes: 16-bit PCM at 44.1 or 48 kHz, one or two channels, 96 / 128 / 160 / 192
    /// kbit/s.
    static func aacAccepts(_ options: CompressedOptions) -> Bool {
        [44100, 48000].contains(options.sampleRate) && [96000, 128_000, 160_000, 192_000].contains(options.bitRate)
    }

    /// The sink for `format` at `url`, or `formatUnsupportedOnThisOS`.
    static func make(_ format: AudioFileFormat, at url: URL) throws -> any AudioFileSink {
        switch format {
        case let .wav(options):
            return try WAVFileSink(url: url, options: options)
        case let .m4a(options):
            guard aacAccepts(options) else { throw AudioExportError.formatUnsupportedOnThisOS(format) }
            return try AACFileSink(url: url, options: options, format: format)
        case .aiff, .mp3:
            throw AudioExportError.formatUnsupportedOnThisOS(format)
        }
    }
}

/// `WAVEncoding` into a file: the header with no length, the samples, then the header again with the length.
final class WAVFileSink: AudioFileSink {
    private let handle: FileHandle
    private let options: PCMOptions
    private var frames = 0
    private var scratch: [UInt8] = []

    init(url: URL, options: PCMOptions) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AudioExportError.fileWriteFailed(underlying: "cannot create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        self.options = options
        try handle.write(contentsOf: WAVEncoding.header(options: options, frameCount: 0))
    }

    func append(_ interleavedStereo: UnsafeBufferPointer<Float>, frames count: Int) throws {
        guard (frames + count) * WAVEncoding.bytesPerFrame(options) <= WAVEncoding.maximumDataBytes else {
            throw AudioExportError.fileWriteFailed(underlying: "a WAV file holds at most 4 GB")
        }
        scratch.removeAll(keepingCapacity: true)
        WAVEncoding.appendSamples(interleavedStereo, frames: count, options: options, to: &scratch)
        try handle.write(contentsOf: scratch)
        frames += count
    }

    func finish() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVEncoding.header(options: options, frameCount: frames))
        try handle.close()
    }

    func abandon() {
        try? handle.close()
    }
}

/// Media Foundation's AAC encoder into an MPEG-4 file (`CMediaFoundation`), handed 16-bit PCM from `WAVEncoding` —
/// little-endian, the layout Media Foundation's PCM input type expects.
final class AACFileSink: AudioFileSink {
    private var writer: OpaquePointer?
    private let pcm: PCMOptions
    private var scratch: [UInt8] = []

    init(url: URL, options: CompressedOptions, format: AudioFileFormat) throws {
        pcm = PCMOptions(sampleRate: options.sampleRate, bitDepth: .int16, channels: options.channels)
        var opened: OpaquePointer?
        let result = url.path.withCString(encodedAs: UTF16.self) { path in
            cmf_aac_open(
                path, UInt32(options.sampleRate), UInt32(options.channels.rawValue), UInt32(options.bitRate), &opened,
            )
        }
        guard result == 0, let opened else {
            if result == Self.notImplemented {
                // No Media Foundation on this Windows.
                throw AudioExportError.formatUnsupportedOnThisOS(format)
            }
            throw AudioExportError.fileWriteFailed(underlying: Self.describe(result, "open"))
        }
        writer = opened
    }

    func append(_ interleavedStereo: UnsafeBufferPointer<Float>, frames: Int) throws {
        guard let writer else { return }
        scratch.removeAll(keepingCapacity: true)
        WAVEncoding.appendSamples(interleavedStereo, frames: frames, options: pcm, to: &scratch)
        let result = scratch.withUnsafeBytes { bytes in
            cmf_aac_write(writer, bytes.bindMemory(to: Int16.self).baseAddress, UInt32(frames))
        }
        guard result == 0 else {
            throw AudioExportError.fileWriteFailed(underlying: Self.describe(result, "write"))
        }
    }

    func finish() throws {
        guard let writer else { return }
        let result = cmf_aac_finish(writer)
        cmf_aac_close(writer)
        self.writer = nil
        guard result == 0 else {
            throw AudioExportError.fileWriteFailed(underlying: Self.describe(result, "finalize"))
        }
    }

    func abandon() {
        cmf_aac_close(writer)
        writer = nil
    }

    /// E_NOTIMPL, what `cmf_aac_open` answers when Media Foundation could not be loaded.
    private static let notImplemented = Int32(bitPattern: 0x8000_4001)

    private static func describe(_ hresult: Int32, _ step: String) -> String {
        "Media Foundation \(step) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))"
    }
}
