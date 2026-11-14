import CMediaFoundation
import Foundation
import SheetMusicAudioCore

/// A recording's probe and decode through Media Foundation's source reader (`CMediaFoundation`): any audio or video
/// file with an audio stream Windows has a decoder for, to interleaved 16-bit PCM at the stream's own rate and channel
/// count. What fills playback's PCM cache (`decodeRecordingCache`) and what a host's import and waveform read
/// (`probe`, `decodePCM16`).
///
/// Media Foundation is loaded at run time, never linked: on a Windows "N" edition without the Media Feature Pack
/// `isDecoderAvailable` is false, `probe` answers `.unreadable` and the decodes throw `Failure.unavailable`.
///
/// A `Reader` is used from the thread that opened it (it joins the multithreaded COM apartment there); the static
/// calls open and close their own on the calling thread, so each may run on any thread, never the render thread.
public enum MediaFoundationAudio {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No Media Foundation source reader on this Windows.
        case unavailable
        /// The file decoded to no frames.
        case empty
        case mediaFoundation(step: String, hresult: Int32)
        case cache(RecordingPCMCacheWriter.Failure)
        /// The raw PCM output could not be written; `code` is the `errno`.
        case writeFailed(code: Int32)

        public var description: String {
            switch self {
            case .unavailable: "Media Foundation's source reader is not available on this Windows"
            case .empty: "the file decoded to no audio"
            case let .mediaFoundation(step, hresult):
                "Media Foundation \(step) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16)))"
            case let .cache(failure): "the PCM cache could not be written (\(failure))"
            case let .writeFailed(code): "the PCM output could not be written (errno \(code))"
            }
        }
    }

    /// What a probe of a file's first audio stream found, without decoding it.
    public struct Probe: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case read
            /// Does not open, holds no stream, or its audio stream gives no format.
            case unreadable
            /// DRM-protected.
            case protected
            /// Streams, none of them audio.
            case noAudioTrack
        }

        public var status: Status
        public var isAACLC: Bool
        /// Bits per second the file states, 0 when it states none.
        public var bitRate: Int
        public var sampleRate: Int
        public var channels: Int
        public var durationSeconds: Double
    }

    /// A decode that landed: its rate and channel count, the frames written, and the start time Media Foundation
    /// stamped on the first block — non-zero when the reader trimmed or shifted the stream's start (an MP4 edit list).
    public struct Decoded: Sendable, Equatable {
        public var sampleRate: Int
        public var channels: Int
        public var frames: Int64
        public var firstBlockStartSeconds: Double
    }

    /// Whether Media Foundation and its source reader load on this Windows. Asked once: installing the Media Feature
    /// Pack takes a restart, so the answer holds for the process.
    public static let isDecoderAvailable = cmf_audio_decoder_available() == 1

    public static func probe(path: String) -> Probe {
        var result = cmf_audio_probe_result()
        _ = path.withCString(encodedAs: UTF16.self) { cmf_audio_probe($0, &result) }
        let status: Probe.Status = switch result.status {
        case CMF_AUDIO_READ: .read
        case CMF_AUDIO_PROTECTED: .protected
        case CMF_AUDIO_NO_AUDIO_TRACK: .noAudioTrack
        default: .unreadable
        }
        return Probe(
            status: status, isAACLC: result.is_aac_lc == 1, bitRate: Int(result.bit_rate),
            sampleRate: Int(result.sample_rate), channels: Int(result.channels),
            durationSeconds: Double(result.duration_100ns) / 10_000_000,
        )
    }

    /// Decodes `sourcePath` into playback's PCM cache (`RecordingPCMCacheWriter`): `<directory>/<cacheKey>-<Hz>.pcm`
    /// at the stream's own rate, stereo — mono doubled, more than two channels reduced to their first two (front left
    /// and right in every Windows channel order). Returns the cache file's path and the decode. The file appears only
    /// once complete.
    public static func decodeRecordingCache(
        sourcePath: String, directory: String, cacheKey: String,
    ) throws(Failure) -> (path: String, decoded: Decoded) {
        let reader = try Reader(path: sourcePath)
        let writer: RecordingPCMCacheWriter
        do {
            writer = try RecordingPCMCacheWriter(
                directory: directory, cacheKey: cacheKey, sampleRate: Double(reader.sampleRate),
            )
        } catch {
            throw .cache(error)
        }
        let channels = reader.channels
        // The first two channels of a block of more, reused while blocks fit.
        var stereo = UnsafeMutablePointer<Int16>.allocate(capacity: 0)
        var stereoFrames = 0
        defer { stereo.deallocate() }
        let decoded: Decoded
        do {
            decoded = try reader.readAll { samples, frames throws(Failure) in
                do {
                    switch channels {
                    case 1: try writer.append(mono: samples, frameCount: frames)
                    case 2: try writer.append(interleavedStereo: samples, frameCount: frames)
                    default:
                        if stereoFrames < frames {
                            stereo.deallocate()
                            stereo = .allocate(capacity: 2 * frames)
                            stereoFrames = frames
                        }
                        for frame in 0 ..< frames {
                            stereo[2 * frame] = samples[frame * channels]
                            stereo[2 * frame + 1] = samples[frame * channels + 1]
                        }
                        try writer.append(interleavedStereo: stereo, frameCount: frames)
                    }
                } catch {
                    throw .cache(error)
                }
            }
        } catch {
            writer.cancel()
            throw error
        }
        do {
            return try (writer.finish(), decoded)
        } catch {
            throw .cache(error)
        }
    }

    /// Decodes `sourcePath` to raw interleaved little-endian 16-bit PCM at `outputPath` (replaced), at the stream's
    /// own rate and channel count: what a host's waveform reads. A failed decode removes the output.
    public static func decodePCM16(sourcePath: String, outputPath: String) throws(Failure) -> Decoded {
        let reader = try Reader(path: sourcePath)
        guard let file = fopen(outputPath, "wb") else { throw .writeFailed(code: _errno().pointee) }
        let channels = reader.channels
        let decoded: Decoded
        do {
            decoded = try reader.readAll { samples, frames throws(Failure) in
                let count = frames * channels
                guard fwrite(samples, 2, count, file) == count else { throw .writeFailed(code: _errno().pointee) }
            }
        } catch {
            fclose(file)
            remove(outputPath)
            throw error
        }
        guard fclose(file) == 0 else {
            let code = _errno().pointee
            remove(outputPath)
            throw .writeFailed(code: code)
        }
        return decoded
    }

    /// A file's first audio stream, decoding block by block.
    public final class Reader {
        public let sampleRate: Int
        public let channels: Int
        private let reader: OpaquePointer

        public init(path: String) throws(Failure) {
            guard MediaFoundationAudio.isDecoderAvailable else { throw .unavailable }
            var opened: OpaquePointer?
            var rate: UInt32 = 0
            var count: UInt32 = 0
            let result = path.withCString(encodedAs: UTF16.self) { cmf_audio_reader_open($0, &opened, &rate, &count) }
            guard result >= 0, let opened, rate > 0, count > 0 else {
                cmf_audio_reader_close(opened)
                throw .mediaFoundation(step: "open", hresult: result)
            }
            reader = opened
            sampleRate = Int(rate)
            channels = Int(count)
        }

        deinit { cmf_audio_reader_close(reader) }

        /// The next block, `frames` interleaved frames valid until the next call; nil at the end of the stream.
        public func next() throws(Failure) -> (samples: UnsafePointer<Int16>, frames: Int, startSeconds: Double)? {
            while true {
                var samples: UnsafePointer<Int16>?
                var frames: UInt32 = 0
                var start: Int64 = 0
                var end: Int32 = 0
                let result = cmf_audio_reader_read(reader, &samples, &frames, &start, &end)
                guard result >= 0 else { throw .mediaFoundation(step: "read", hresult: result) }
                if end == 1 { return nil }
                if frames > 0, let samples { return (samples, Int(frames), Double(start) / 10_000_000) }
            }
        }

        /// Hands every block to `body` in order and returns the decode. Throws `.empty` for no frames.
        func readAll(
            _ body: (UnsafePointer<Int16>, Int) throws(Failure) -> Void,
        ) throws(Failure) -> Decoded {
            var total: Int64 = 0
            var firstStart: Double?
            while let block = try next() {
                if firstStart == nil { firstStart = block.startSeconds }
                try body(block.samples, block.frames)
                total += Int64(block.frames)
            }
            guard total > 0 else { throw .empty }
            return Decoded(
                sampleRate: sampleRate, channels: channels, frames: total, firstBlockStartSeconds: firstStart ?? 0,
            )
        }
    }
}
