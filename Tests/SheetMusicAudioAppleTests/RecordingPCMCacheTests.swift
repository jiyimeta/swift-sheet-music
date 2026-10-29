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

    /// Signal power of `frequency` in one channel of interleaved frames (Goertzel).
    private func power(
        _ base: UnsafePointer<Int16>, frames: Int, channel: Int, frequency: Double, rate: Double,
    ) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / rate)
        var previous = 0.0, beforePrevious = 0.0
        for index in 0 ..< frames {
            let current = Double(base[2 * index + channel]) / 32768 + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return (previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious)
            / Double(frames * frames)
    }

    @Test(arguments: [("m4a", 0), ("aac", 0), ("aac", 1500)])
    func stereoAACEndsCleanlyAndKeepsChannelOrder(container: String, truncatedBytes: Int) async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("stereo.\(container)")
        let rate = 44100.0
        let count = Int(3 * rate)
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try #require(buffer.floatChannelData)
            for index in 0 ..< count {
                let time = Double(index) / rate
                channels[0][index] = Float(0.5 * sin(2 * Double.pi * 440 * time))
                channels[1][index] = Float(0.5 * sin(2 * Double.pi * 660 * time))
            }
            let file = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2,
            ])
            try file.write(from: buffer)
        }
        if truncatedBytes > 0 {
            let data = try Data(contentsOf: source)
            try data.prefix(data.count - truncatedBytes).write(to: source)
        }

        let cache = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "aac", sampleRate: 48000, directory: scratch.directory,
        )
        let mapped = try MappedRecording(pcmFile: cache)
        defer { withExtendedLifetime(mapped) {} }
        let frames = mapped.frames
        // AAC adds priming and padding frames, so allow a couple of packets (1024 frames each) either way.
        let expected = 3 * 48000
        let shortfall = truncatedBytes > 0 ? 12000 : 0
        let deviation = abs(frames.frameCount + shortfall / 2 - expected)
        #expect(deviation <= 4096 + shortfall / 2, "got \(frames.frameCount) frames, expected ~\(expected)")
        func band(_ channel: Int, _ frequency: Double) -> Double {
            power(frames.base, frames: frames.frameCount, channel: channel, frequency: frequency, rate: 48000)
        }
        #expect(band(0, 440) > 20 * band(0, 660))
        #expect(band(1, 660) > 20 * band(1, 440))
    }

    /// A WAV whose header promises more data than the file holds, as an interrupted download leaves.
    @Test func wavWithOverstatedDataChunkEndsCleanly() async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("cut.wav")
        _ = try writeSine(to: source, seconds: 3, sampleRate: 48000)
        let data = try Data(contentsOf: source)
        try data.prefix(data.count - 40000).write(to: source)

        let cache = try await RecordingPCMCache.prepare(
            source: source, cacheKey: "cut", sampleRate: 48000, directory: scratch.directory,
        )
        let count = try MappedRecording(pcmFile: cache).frames.frameCount
        #expect(abs(count - (3 * 48000 - 10000)) <= 1, "got \(count) frames")
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

    /// Each of these used to trap converting the rate for the file name or the header (NaN, ±∞, beyond `UInt32`), or
    /// fail later as a decode error (zero, negative, under 1 Hz once rounded).
    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -48000, 0.4, 5e9])
    func aSampleRateThatIsNotARateThrowsBeforeAnythingIsWritten(rate: Double) async throws {
        let scratch = try Scratch()
        let source = scratch.directory.appendingPathComponent("tone.wav")
        _ = try writeSine(to: source, seconds: 0.1, sampleRate: 48000)

        await #expect(throws: RecordingPCMCache.Failure.invalidSampleRate) {
            try await RecordingPCMCache.prepare(
                source: source, cacheKey: "k", sampleRate: rate, directory: scratch.directory,
            )
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: scratch.directory.path)
        #expect(written == ["tone.wav"], "\(written)")
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
