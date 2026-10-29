@preconcurrency import AVFoundation
import Foundation

/// Decodes a recording once into an Int16 stereo PCM file that `MappedRecording` maps, so that several recordings
/// need no more resident memory than the pages being played.
///
/// File layout, little-endian: `"SMPC"`, UInt32 version (1), UInt32 frame count, UInt32 sample rate in Hz, then
/// `frameCount × 2` Int16 samples, interleaved left and right.
public enum RecordingPCMCache {
    public enum Failure: Error, Equatable {
        /// There is no file at the source URL.
        case noFile
        /// AVFoundation does not read the source as audio.
        case notARecording(String)
        /// The source opened but decoding it failed.
        case decodeFailed(String)
        /// The decoded audio does not fit the cache format (empty, or more than UInt32 frames).
        case invalidLength(frames: Int)
        /// The sample rate asked for is not finite, or does not round to 1 … `UInt32.max` Hz.
        case invalidSampleRate
    }

    /// Decodes `source` (anything `AVAudioFile` reads; mono is duplicated to both channels) to interleaved Int16
    /// stereo at `sampleRate` and writes it to `directory/<cacheKey>-<sampleRate in whole Hz>.pcm`, returning that URL.
    /// An existing valid file is reused untouched; an invalid one is rebuilt. Decoding runs off the caller's actor and
    /// stops between chunks when the task is cancelled. A `sampleRate` that is not finite or does not round to
    /// 1 … `UInt32.max` Hz throws `.invalidSampleRate` before anything is read or written.
    @concurrent
    public static func prepare(
        source: URL, cacheKey: String, sampleRate: Double, directory: URL,
    ) async throws -> URL {
        let wholeHertz = sampleRate.rounded()
        guard wholeHertz.isFinite, wholeHertz >= 1, wholeHertz <= Double(UInt32.max) else {
            throw Failure.invalidSampleRate
        }
        let destination = directory.appendingPathComponent("\(cacheKey)-\(Int(wholeHertz)).pcm")
        if (try? MappedRecording(pcmFile: destination)) != nil { return destination }
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.noFile }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) } catch {
            throw Failure.notARecording(error.localizedDescription)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(cacheKey)-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw Failure.decodeFailed("cannot create \(temporary.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(count: MappedRecording.headerSize))
            let frameCount = try decode(file, to: handle, sampleRate: sampleRate)
            guard frameCount > 0, frameCount <= Int(UInt32.max) else { throw Failure.invalidLength(frames: frameCount) }
            // The header goes in last, so a file the process died writing has no magic and fails validation.
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(frameCount: frameCount, sampleRate: sampleRate))
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else {
                throw Failure.decodeFailed("cannot move the cache file into place (errno \(errno))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    private static func header(frameCount: Int, sampleRate: Double) -> Data {
        var data = Data(MappedRecording.magic)
        for value in [MappedRecording.version, UInt32(frameCount), UInt32(sampleRate.rounded())] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Reads `file` through a converter and appends interleaved Int16 chunks to `handle`; returns the frame count.
    private static func decode( // swiftlint:disable:this function_body_length
        _ file: AVAudioFile, to handle: FileHandle, sampleRate: Double,
    ) throws -> Int {
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw Failure.decodeFailed("no stereo float format at \(sampleRate) Hz")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.decodeFailed("no converter from \(inputFormat)")
        }
        if inputFormat.channelCount == 1 {
            converter.channelMap = [0, 0]
        }
        let inputCapacity: AVAudioFrameCount = 32768
        let ratio = sampleRate / inputFormat.sampleRate
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(Double(inputCapacity) * ratio) + 4096,
              )
        else { throw Failure.decodeFailed("buffer allocation") }

        final class Feed: @unchecked Sendable {
            var reachedEnd = false
            var readError: (any Error)?
        }
        let feed = Feed()
        var total = 0

        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packets, inputStatus in
                // `AVAudioFile.read` THROWS at end of file (eofErr −39 in the app, a bare nilError from a script)
                // rather than returning no frames, and the converter always asks once more after the last real
                // buffer — so end the stream at `length` instead of reading into the end.
                let remaining = file.length - file.framePosition
                if feed.reachedEnd || remaining <= 0 {
                    feed.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let frames = min(Int64(min(packets, inputCapacity)), remaining)
                    try file.read(into: inputBuffer, frameCount: AVAudioFrameCount(frames))
                } catch {
                    // A compressed file's `length` can overstate it; failing at its real end is still the end.
                    if (error as NSError).code != Int(kAudioFileEndOfFileError) {
                        feed.readError = error
                    }
                    feed.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    feed.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError = feed.readError { throw Failure.decodeFailed(readError.localizedDescription) }
            if status == .error {
                throw Failure.decodeFailed(conversionError?.localizedDescription ?? "conversion error")
            }
            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let channels = outputBuffer.floatChannelData {
                var samples = [Int16](repeating: 0, count: frames * 2)
                for index in 0 ..< frames {
                    samples[2 * index] = int16(channels[0][index])
                    samples[2 * index + 1] = int16(channels[1][index])
                }
                try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
                total += frames
            }
            if status == .endOfStream || status == .inputRanDry { break }
            if frames == 0, feed.reachedEnd { break }
        }
        return total
    }

    private static func int16(_ value: Float) -> Int16 {
        Int16(max(-32767, min(32767, (value * 32767).rounded())))
    }
}
