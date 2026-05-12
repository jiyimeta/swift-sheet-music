import AVFoundation
@testable import SheetMusicAudio
import Testing

@Suite("PlaybackState .exporting")
struct PlaybackStateExportingCaseTests {
    @Test(".exporting is a distinct case")
    func exportingIsDistinct() {
        let s: PlaybackState = .exporting
        #expect(s == .exporting)
        #expect(s != .playing)
        #expect(s != .paused)
        #expect(s != .stopped)
    }
}

@Suite("PCMAudioExportWriter")
struct PCMAudioExportWriterTests {
    /// Writing one buffer of silence to a .wav and reading it back
    /// yields the expected sample rate / channels / frame count.
    @Test("WAV writer round-trip")
    func wavRoundTrip() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let options = PCMOptions(sampleRate: 22050, bitDepth: .int16, channels: .mono)
        let writer = try PCMAudioExportWriter(
            url: url, format: .wav(options),
        )

        let inFmt = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 22050,
            channels: 1,
            interleaved: false,
        ))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 1024))
        buf.frameLength = 1024

        try await writer.write(buf)
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 22050)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 1024)
    }

    @Test("AIFF writer round-trip")
    func aiffRoundTrip() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try PCMAudioExportWriter(
            url: url, format: .aiff(PCMOptions()),
        )
        let inFmt = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false,
        ))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 512))
        buf.frameLength = 512
        try await writer.write(buf)
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 44100)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.length == 512)
    }
}

@Suite("CompressedAudioExportWriter (M4A)")
struct CompressedAudioExportWriterTests {
    @Test("M4A writer produces an AAC file")
    func m4aRoundTrip() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CompressedAudioExportWriter(
            url: url, format: .m4a(CompressedOptions(bitRate: 128_000)),
        )
        let inFmt = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false,
        ))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096))
        buf.frameLength = 4096
        try await writer.write(buf)
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        let desc = file.fileFormat.streamDescription.pointee
        #expect(desc.mFormatID == kAudioFormatMPEG4AAC)
    }
}
