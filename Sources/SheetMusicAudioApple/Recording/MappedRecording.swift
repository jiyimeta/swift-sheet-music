import Foundation
import SheetMusicAudioCore

/// A decoded recording's PCM cache file (see `RecordingPCMCache`) mapped read-only into memory. The kernel drops clean
/// pages under pressure, so a long recording costs address space rather than resident memory. Immutable after `init`.
///
/// A page the render thread reads that is not resident faults, and the read waits for the disk: a dropout. The mapping
/// is marked sequential, so the kernel reads ahead of a steady read; for what that cannot foresee (the first read after
/// a seek, a loop wrap or a cut to another segment, or pages dropped under pressure since) the host asks for the pages
/// ahead of time from another thread (`prefetch(seconds:)`, which `PlaybackEngine` calls).
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
        // Advice only: a kernel that ignores it still maps the file.
        _ = madvise(address, length, MADV_SEQUENTIAL)
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

    /// Asks the kernel to start reading in the pages that hold `seconds` of the file, so the render thread finds them
    /// resident. Advice, and asynchronous for a file mapping: it returns without waiting for the disk. Never call it
    /// on the render thread.
    func prefetch(seconds: Range<TimeInterval>) {
        guard let bytes = Self.prefetchBytes(
            seconds: seconds, sampleRate: sampleRate, frameCount: frameCount, pageSize: Int(getpagesize()),
        ) else { return }
        _ = madvise(mapping + bytes.lowerBound, bytes.count, MADV_WILLNEED)
    }

    /// The bytes of the mapping, from its start and widened to whole pages, that hold the frames of `seconds` — and
    /// the frame after the last, which an interpolated read takes too. Nil when the file has none of them.
    static func prefetchBytes(
        seconds: Range<TimeInterval>, sampleRate: Double, frameCount: Int, pageSize: Int,
    ) -> Range<Int>? {
        guard seconds.lowerBound.isFinite, seconds.upperBound.isFinite, sampleRate > 0, frameCount > 0, pageSize > 0
        else { return nil }
        let first = max(0, (seconds.lowerBound * sampleRate).rounded(.down))
        let last = min(Double(frameCount), (seconds.upperBound * sampleRate).rounded(.up) + 1)
        guard last > first else { return nil }
        let start = headerSize + Int(first) * 4
        let end = headerSize + Int(last) * 4
        let mappedPages = (headerSize + frameCount * 4 + pageSize - 1) / pageSize
        return start / pageSize * pageSize ..< min((end + pageSize - 1) / pageSize, mappedPages) * pageSize
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
