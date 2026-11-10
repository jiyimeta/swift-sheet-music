import SheetMusicFoundation

/// A decoded recording's PCM cache file (`RecordingPCMCacheFormat`) mapped read-only into memory. The kernel drops
/// clean pages under pressure, so a long recording costs address space rather than resident memory. Immutable after
/// `init`.
///
/// A page the render thread reads that is not resident faults, and the read waits for the disk: a dropout. The mapping
/// is marked sequential, so the kernel reads ahead of a steady read; for what that cannot foresee (the first read after
/// a seek, a loop wrap or a cut to another segment, or pages dropped under pressure since) the host asks for the pages
/// ahead of time from another thread (`prefetch(seconds:)`).
///
/// Where the platform has no `mmap` (WebAssembly, Windows) the file is read into memory whole instead, so the type and
/// its validation are the same everywhere.
public final class MappedRecording: @unchecked Sendable {
    /// Why a file was not accepted as a PCM cache file.
    public enum Failure: Error, Equatable {
        /// The file could not be opened, read or mapped; `code` is the `errno`.
        case unreadable(code: Int32)
        /// The magic or version does not match, or the size is not exactly the header plus `frameCount` frames.
        case invalidCacheFile
    }

    package static let headerSize = RecordingPCMCacheFormat.headerSize
    package static let magic = RecordingPCMCacheFormat.magic
    package static let version = RecordingPCMCacheFormat.version

    private let storage: Storage
    private let frameCount: Int
    private let sampleRate: Double

    /// Maps `pcmFile`, throwing when it is not a complete cache file.
    public convenience init(pcmFile: URL) throws {
        try self.init(path: pcmFile.path)
    }

    /// Maps the cache file at `path`, throwing when it is not a complete cache file.
    public init(path: String) throws {
        let opened = try Storage.load(path: path)
        storage = opened.storage
        frameCount = opened.frameCount
        sampleRate = opened.sampleRate
    }

    /// The recording's length in seconds at its cached sample rate.
    public var durationSeconds: TimeInterval {
        Double(frameCount) / sampleRate
    }

    /// The mapped frames. Valid for as long as this object lives.
    package var frames: PCMFrames {
        let samples = (storage.base + Self.headerSize).assumingMemoryBound(to: Int16.self)
        return PCMFrames(base: UnsafePointer(samples), frameCount: frameCount, sampleRate: sampleRate)
    }

    /// Asks the kernel to start reading in the pages that hold `seconds` of the file, so the render thread finds them
    /// resident. Advice, and asynchronous for a file mapping: it returns without waiting for the disk. Never call it
    /// on the render thread. A no-op where the file was read whole.
    package func prefetch(seconds: Range<TimeInterval>) {
        storage.prefetch(seconds: seconds, sampleRate: sampleRate, frameCount: frameCount)
    }

    /// The bytes of the mapping, from its start and widened to whole pages, that hold the frames of `seconds` — and
    /// the frame after the last, which an interpolated read takes too. Nil when the file has none of them.
    package static func prefetchBytes(
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
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)
    extension MappedRecording {
        /// The file mapped with `mmap`, unmapped when the recording is released.
        final class Storage {
            let base: UnsafeMutableRawPointer
            let length: Int

            private init(base: UnsafeMutableRawPointer, length: Int) {
                self.base = base
                self.length = length
            }

            deinit { munmap(base, length) }

            static func load(path: String) throws -> (storage: Storage, frameCount: Int, sampleRate: Double) {
                let descriptor = open(path, O_RDONLY)
                guard descriptor >= 0 else { throw Failure.unreadable(code: errno) }
                defer { close(descriptor) }

                var header = [UInt8](repeating: 0, count: headerSize)
                let headerRead = pread(descriptor, &header, headerSize, 0)
                guard headerRead == headerSize else {
                    if headerRead < 0 { throw Failure.unreadable(code: errno) }
                    throw Failure.invalidCacheFile
                }
                guard let parsed = RecordingPCMCacheFormat.parseHeader(header) else { throw Failure.invalidCacheFile }
                var status = stat()
                guard fstat(descriptor, &status) == 0 else { throw Failure.unreadable(code: errno) }
                guard Int64(status.st_size) == RecordingPCMCacheFormat.fileSize(frameCount: parsed.frameCount) else {
                    throw Failure.invalidCacheFile
                }

                let length = headerSize + parsed.frameCount * 4
                // Optional on Darwin and Glibc, not on Bionic: typed here so one binding reads both.
                let address: UnsafeMutableRawPointer? = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0)
                // `MAP_FAILED` is `(void *)-1`, a macro not every platform overlay spells out.
                guard let address, Int(bitPattern: address) != -1 else { throw Failure.unreadable(code: errno) }
                // Advice only: a kernel that ignores it still maps the file.
                _ = madvise(address, length, MADV_SEQUENTIAL)
                return (Storage(base: address, length: length), parsed.frameCount, Double(parsed.sampleRate))
            }

            func prefetch(seconds: Range<TimeInterval>, sampleRate: Double, frameCount: Int) {
                guard let bytes = MappedRecording.prefetchBytes(
                    seconds: seconds, sampleRate: sampleRate, frameCount: frameCount,
                    pageSize: Int(sysconf(Int32(_SC_PAGESIZE))),
                ) else { return }
                _ = madvise(base + bytes.lowerBound, bytes.count, MADV_WILLNEED)
            }
        }
    }

#else
    extension MappedRecording {
        /// The file read into memory whole, on a platform without `mmap`.
        ///
        /// Right for WebAssembly, which has no mapping to fall back on. Windows does: before it plays recordings, give
        /// it a `CreateFileMapping` / `MapViewOfFile` storage of its own, since reading the whole file here makes a
        /// long recording cost its full size in resident memory and blocks the call that maps it until the read ends.
        final class Storage {
            let base: UnsafeMutableRawPointer
            let length: Int

            private init(base: UnsafeMutableRawPointer, length: Int) {
                self.base = base
                self.length = length
            }

            deinit { base.deallocate() }

            static func load(path: String) throws -> (storage: Storage, frameCount: Int, sampleRate: Double) {
                guard let file = fopen(path, "rb") else { throw Failure.unreadable(code: cErrno) }
                defer { fclose(file) }
                var header = [UInt8](repeating: 0, count: headerSize)
                guard fread(&header, 1, headerSize, file) == headerSize else { throw Failure.invalidCacheFile }
                guard let parsed = RecordingPCMCacheFormat.parseHeader(header) else { throw Failure.invalidCacheFile }
                guard fseek(file, 0, SEEK_END) == 0 else { throw Failure.unreadable(code: cErrno) }
                let size = Int64(ftell(file))
                guard size == RecordingPCMCacheFormat.fileSize(frameCount: parsed.frameCount) else {
                    throw Failure.invalidCacheFile
                }
                let length = Int(size)
                let base = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
                guard fseek(file, 0, SEEK_SET) == 0, fread(base, 1, length, file) == length else {
                    base.deallocate()
                    throw Failure.unreadable(code: cErrno)
                }
                return (Storage(base: base, length: length), parsed.frameCount, Double(parsed.sampleRate))
            }

            func prefetch(seconds _: Range<TimeInterval>, sampleRate _: Double, frameCount _: Int) {}
        }
    }
#endif
