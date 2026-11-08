import SheetMusicFoundation

/// Writes a PCM cache file (`RecordingPCMCacheFormat`) from samples a platform's own decoder produces — Android's
/// MediaCodec decoder hands its PCM here over JNI, so the format has one writer.
///
/// The file is written under a temporary name in its directory, with a zeroed header; `finish()` writes the header
/// last and renames the file into place in one step, so a reader never maps a half-written file under the final name,
/// and a file whose writer died has no magic. Not thread-safe: one writer per decode.
public final class RecordingPCMCacheWriter {
    public enum Failure: Error, Equatable {
        /// The sample rate is not finite, or does not round to 1 … `UInt32.max` Hz.
        case invalidSampleRate
        /// The decoded audio does not fit the format: no frames, or more than `UInt32.max`.
        case invalidLength(frames: Int)
        /// The file could not be created, written or moved into place; `code` is the `errno`.
        case writeFailed(code: Int32)
        /// `append` or `finish` after `finish` or `cancel`.
        case closed
    }

    /// The path `finish()` moves the file to: `<directory>/<cacheKey>-<Hz>.pcm`.
    public let destinationPath: String
    private let temporaryPath: String
    private let sampleRate: Double
    private var file: UnsafeMutablePointer<FILE>?
    private var framesWritten = 0

    /// The path of a valid cache file for `cacheKey` at `sampleRate` in `directory`, when one is there already: a
    /// decoder skips the decode and plays it. Nil when there is none or it does not validate.
    public static func existingFile(directory: String, cacheKey: String, sampleRate: Double) -> String? {
        guard let name = RecordingPCMCacheFormat.fileName(cacheKey: cacheKey, sampleRate: sampleRate) else {
            return nil
        }
        let path = directory + "/" + name
        return (try? MappedRecording(path: path)) != nil ? path : nil
    }

    /// Starts a file for `cacheKey` at `sampleRate` in `directory`, which must exist. Throws `.invalidSampleRate`
    /// before anything is written, and `.writeFailed` when the temporary file cannot be created.
    public init(directory: String, cacheKey: String, sampleRate: Double) throws(Failure) {
        guard let name = RecordingPCMCacheFormat.fileName(cacheKey: cacheKey, sampleRate: sampleRate) else {
            throw .invalidSampleRate
        }
        destinationPath = directory + "/" + name
        let suffix = String(UInt64.random(in: 0 ... UInt64.max), radix: 16)
        temporaryPath = directory + "/.\(cacheKey)-\(suffix).tmp"
        self.sampleRate = sampleRate
        guard let file = fopen(temporaryPath, "wb") else { throw .writeFailed(code: errno) }
        self.file = file
        let header = [UInt8](repeating: 0, count: RecordingPCMCacheFormat.headerSize)
        guard fwrite(header, 1, header.count, file) == header.count else {
            let code = errno
            cancel()
            throw .writeFailed(code: code)
        }
    }

    deinit { cancel() }

    /// Appends `frameCount` interleaved stereo frames (`samples[2i]` left, `samples[2i + 1]` right).
    public func append(interleavedStereo samples: UnsafePointer<Int16>, frameCount: Int) throws(Failure) {
        guard let file else { throw .closed }
        guard frameCount > 0 else { return }
        try write(samples, count: frameCount * 2, to: file)
        framesWritten += frameCount
    }

    /// Appends `frameCount` mono frames, each written to both channels.
    public func append(mono samples: UnsafePointer<Int16>, frameCount: Int) throws(Failure) {
        guard let file else { throw .closed }
        guard frameCount > 0 else { return }
        let capacity = min(frameCount, 4096)
        let stereo = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * capacity)
        defer { stereo.deallocate() }
        var done = 0
        while done < frameCount {
            let chunk = min(frameCount - done, capacity)
            for index in 0 ..< chunk {
                stereo[2 * index] = samples[done + index]
                stereo[2 * index + 1] = samples[done + index]
            }
            try write(stereo, count: chunk * 2, to: file)
            done += chunk
        }
        framesWritten += frameCount
    }

    /// Writes the header, closes the file and moves it to `destinationPath`, replacing a file there, and returns that
    /// path. Throws `.invalidLength` for no frames (or more than the format holds) and removes the temporary file on
    /// any failure.
    @discardableResult
    public func finish() throws(Failure) -> String {
        guard let file else { throw .closed }
        guard let header = RecordingPCMCacheFormat.header(frameCount: framesWritten, sampleRate: sampleRate) else {
            let frames = framesWritten
            cancel()
            throw .invalidLength(frames: frames)
        }
        guard fseek(file, 0, SEEK_SET) == 0, fwrite(header, 1, header.count, file) == header.count else {
            let code = errno
            cancel()
            throw .writeFailed(code: code)
        }
        self.file = nil
        guard fclose(file) == 0 else {
            let code = errno
            remove(temporaryPath)
            throw .writeFailed(code: code)
        }
        guard rename(temporaryPath, destinationPath) == 0 else {
            let code = errno
            remove(temporaryPath)
            throw .writeFailed(code: code)
        }
        return destinationPath
    }

    /// Abandons the file: closes and removes it. Safe to call more than once, and after `finish()`.
    public func cancel() {
        guard let file else { return }
        self.file = nil
        fclose(file)
        remove(temporaryPath)
    }

    private func write(
        _ samples: UnsafePointer<Int16>, count: Int, to file: UnsafeMutablePointer<FILE>,
    ) throws(Failure) {
        // The format is little-endian, as every platform this runs on is; a big-endian host would swap here.
        guard fwrite(samples, MemoryLayout<Int16>.size, count, file) == count else {
            let code = errno
            cancel()
            throw .writeFailed(code: code)
        }
    }
}
