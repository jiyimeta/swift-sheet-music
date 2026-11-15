import Foundation
import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
import Testing

/// `MediaFoundationAudio.Reader` asked for a rate and channel count other than the stream's: Media Foundation's source
/// reader converts them itself, or refuses at open. What an import's encode reads a 22.05 kHz or a mono source through.
@Suite(.enabled(if: MediaFoundationAudio.isDecoderAvailable))
struct MediaFoundationReaderConversionTests {
    private static func temporaryPath(_ suffix: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ssm-mfc-\(UUID().uuidString)\(suffix)").path
    }

    /// One second of a 441 Hz stereo sine at `rate`.
    private static func writeSine(at path: String, rate: Double, channels: AudioChannelCount) throws {
        let frames = Int(rate)
        let options = PCMOptions(sampleRate: rate, bitDepth: .int16, channels: channels)
        let sink = try PCMFileSink(url: URL(fileURLWithPath: path), options: options, encoding: .wav)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0 ..< frames {
            let value = Float(sin(2 * Double.pi * 441 * Double(frame) / rate) * 0.5)
            samples[2 * frame] = value
            samples[2 * frame + 1] = value
        }
        try samples.withUnsafeBufferPointer { try sink.append($0, frames: frames) }
        try sink.finish()
    }

    private static func readAllFrames(_ reader: MediaFoundationAudio.Reader) throws -> Int {
        var total = 0
        while let block = try reader.next() {
            total += block.frames
        }
        return total
    }

    @Test(arguments: [(22050.0, 48000, 2), (44100.0, 48000, 2), (48000.0, 44100, 1), (22050.0, 44100, 1)])
    func `the reader converts a source's rate and channels when asked`(
        source: Double, rate: Int, channels: Int,
    ) throws {
        let wav = Self.temporaryPath(".wav")
        defer { try? FileManager.default.removeItem(atPath: wav) }
        try Self.writeSine(at: wav, rate: source, channels: .stereo)

        let reader = try MediaFoundationAudio.Reader(path: wav, sampleRate: rate, channels: channels)
        #expect(reader.sampleRate == rate && reader.channels == channels)
        let frames = try Self.readAllFrames(reader)
        #expect(abs(frames - rate) <= rate / 100, "\(frames) frames for one second at \(rate) Hz")
    }
}
