@preconcurrency import AVFoundation
import Foundation
@testable import SheetMusicAudioApple
import Testing

struct RecordingPCMCacheTests {
    /// A fresh directory the test removes when it ends.
    private final class Scratch {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RecordingPCMCacheTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Writes a mono 32-bit float WAV of a 440 Hz sine and returns the samples it holds.
    private func writeSine(to url: URL, seconds: Double, sampleRate: Double) throws -> [Float] {
        let count = Int(seconds * sampleRate)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        var samples: [Float] = []
        for index in 0 ..< count {
            samples.append(Float(0.5 * sin(2 * Double.pi * 440 * Double(index) / sampleRate)))
        }
        let channel = try #require(buffer.floatChannelData)[0]
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        return samples
    }

    private func header(frameCount: UInt32, sampleRate: UInt32, magic: String = "SMPC") -> Data {
        var data = Data(magic.utf8)
        for value in [UInt32(1), frameCount, sampleRate] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func monoWavRoundTripsToStereoWithinOneLSB() async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("tone.wav")
        let samples = try writeSine(to: source, seconds: 3, sampleRate: 48000)

        let cache = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "tone", sampleRate: 48000, directory: scratch.directory,
        )
        #expect(cache.lastPathComponent == "tone-48000.pcm")
        let mapped = try MappedRecording(pcmFile: cache)
        let frames = mapped.frames
        #expect(frames.frameCount == samples.count)
        #expect(frames.sampleRate == 48000)
        #expect(abs(mapped.durationSeconds - 3) < 1e-9)
        var worst = 0.0
        for index in 0 ..< samples.count {
            let expected = Double(samples[index]) * 32767
            worst = max(worst, abs(Double(frames.base[2 * index]) - expected))
            worst = max(worst, abs(Double(frames.base[2 * index + 1]) - expected))
        }
        #expect(worst <= 1, "worst deviation \(worst) LSB over \(samples.count) frames")
    }

    @Test func resamplesTo48kHz() async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("slow.wav")
        _ = try writeSine(to: source, seconds: 3, sampleRate: 22050)

        let cache = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "slow", sampleRate: 48000, directory: scratch.directory,
        )
        let frames = try MappedRecording(pcmFile: cache).frames
        #expect(abs(frames.frameCount - 48000 * 3) <= 1, "got \(frames.frameCount) frames")
        #expect(frames.sampleRate == 48000)
    }

    @Test func secondPrepareReusesTheFile() async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("tone.wav")
        _ = try writeSine(to: source, seconds: 1, sampleRate: 48000)
        let first = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "k", sampleRate: 48000, directory: scratch.directory,
        )
        let before = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100))
        let second = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "k", sampleRate: 48000, directory: scratch.directory,
        )
        let after = try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date
        #expect(first == second)
        #expect(before != nil)
        #expect(before == after)
    }

    @Test func truncatedFileIsRejectedAndRebuilt() async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("tone.wav")
        _ = try writeSine(to: source, seconds: 1, sampleRate: 48000)
        let cache = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "k", sampleRate: 48000, directory: scratch.directory,
        )
        let full = try Data(contentsOf: cache)
        try full.prefix(full.count - 10).write(to: cache)

        #expect(throws: MappedRecording.Failure.self) { try MappedRecording(pcmFile: cache) }
        let rebuilt = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "k", sampleRate: 48000, directory: scratch.directory,
        )
        #expect(try MappedRecording(pcmFile: rebuilt).frames.frameCount == 48000)
    }

    @Test func wrongMagicIsRejectedAndRebuilt() async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("tone.wav")
        _ = try writeSine(to: source, seconds: 1, sampleRate: 48000)
        let cache = scratch.directory.appendingPathComponent("k-48000.pcm")
        var bad = header(frameCount: 10, sampleRate: 48000, magic: "XXXX")
        bad.append(Data(count: 40))
        try bad.write(to: cache)

        #expect(throws: MappedRecording.Failure.self) { try MappedRecording(pcmFile: cache) }
        let rebuilt = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "k", sampleRate: 48000, directory: scratch.directory,
        )
        #expect(try MappedRecording(pcmFile: rebuilt).frames.frameCount == 48000)
    }

    @Test func missingSourceThrows() async throws {
        let scratch = try Scratch()
        await #expect(throws: RecordingPCMCache.Failure.self) {
            try await RecordingPCMCache.prepare(
                source: scratch.directory.appendingPathComponent("nope.wav"),
                cacheKey: "k", sampleRate: 48000, directory: scratch.directory,
            )
        }
    }

    @Test func mappingASixMinuteFileDoesNotMakeItResident() throws {
        let scratch = try Scratch()
        let frameCount = 360 * 48000
        let url = scratch.directory.appendingPathComponent("long-48000.pcm")
        try header(frameCount: UInt32(frameCount), sampleRate: 48000).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(16 + frameCount * 4))
        try handle.close()

        let before = Self.residentBytes()
        let mapped = try MappedRecording(pcmFile: url)
        let after = Self.residentBytes()
        #expect(mapped.frames.frameCount == frameCount)
        #expect(after < before + 10_000_000, "resident grew by \(Int(after) - Int(before)) bytes")
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return UInt64(info.resident_size)
    }
}
