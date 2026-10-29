import Foundation
import SheetMusicAudioCore

/// A decoded recording's PCM cache file (see `RecordingPCMCache`) mapped read-only into memory. The pages are faulted
/// in by the render thread as it reads them and the kernel drops them under pressure, so a long recording costs
/// address space rather than resident memory. Immutable after `init`.
public final class MappedRecording: @unchecked Sendable {
    /// Why a file was not accepted as a PCM cache file.
    public enum Failure: Error, Equatable {
        /// The file could not be opened, read or mapped; `code` is the `errno`.
        case unreadable(code: Int32)
        /// The magic or version does not match, or the size is not exactly the header plus `frameCount` frames.
        case invalidCacheFile
    }

    package static let headerSize = 16
    package static let magic: [UInt8] = Array("SMPC".utf8)
    package static let version: UInt32 = 1

    private let mapping: UnsafeMutableRawPointer
    private let mappedLength: Int
    private let frameCount: Int
    private let sampleRate: Double

    /// Maps `pcmFile`, throwing when it is not a complete cache file.
    public init(pcmFile: URL) throws {
        let descriptor = open(pcmFile.path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure.unreadable(code: errno) }
        defer { close(descriptor) }

        var header = [UInt8](repeating: 0, count: Self.headerSize)
        let headerRead = pread(descriptor, &header, Self.headerSize, 0)
        guard headerRead == Self.headerSize else {
            if headerRead < 0 { throw Failure.unreadable(code: errno) }
            throw Failure.invalidCacheFile
        }
        guard Array(header[0 ..< 4]) == Self.magic, Self.word(header, at: 4) == Self.version else {
            throw Failure.invalidCacheFile
        }
        let frames = Int(Self.word(header, at: 8))
        let rate = Int(Self.word(header, at: 12))
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Failure.unreadable(code: errno) }
        guard rate > 0, Int64(status.st_size) == Int64(Self.headerSize) + Int64(frames) * 4 else {
            throw Failure.invalidCacheFile
        }

        let length = Self.headerSize + frames * 4
        let address = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let address, address != MAP_FAILED else { throw Failure.unreadable(code: errno) }
        mapping = address
        mappedLength = length
        frameCount = frames
        sampleRate = Double(rate)
    }

    deinit { munmap(mapping, mappedLength) }

    /// The recording's length in seconds at its cached sample rate.
    public var durationSeconds: TimeInterval {
        Double(frameCount) / sampleRate
    }

    /// The mapped frames. Valid for as long as this object lives.
    package var frames: PCMFrames {
        let samples = (mapping + Self.headerSize).assumingMemoryBound(to: Int16.self)
        return PCMFrames(base: UnsafePointer(samples), frameCount: frameCount, sampleRate: sampleRate)
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
