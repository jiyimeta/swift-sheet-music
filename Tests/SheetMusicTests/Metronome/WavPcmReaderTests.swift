import Foundation
@testable import SheetMusicAudioCore
import Testing

struct WavPcmReaderTests {
    @Test func reads16BitMono() throws {
        let wav = WavTestSupport.pcm16(
            interleaved: [100, -100, 200], channels: 1, sampleRate: 22050,
        )
        let result = try WavPcmReader.read(wav)
        #expect(result.samples == [100, -100, 200])
        #expect(result.sampleRate == 22050)
    }

    @Test func downmixes16BitStereoToMono() throws {
        // Frame 0: L=100 R=300 → 200. Frame 1: L=200 R=400 → 300.
        let wav = WavTestSupport.pcm16(
            interleaved: [100, 300, 200, 400], channels: 2, sampleRate: 44100,
        )
        let result = try WavPcmReader.read(wav)
        #expect(result.samples == [200, 300])
        #expect(result.sampleRate == 44100)
    }

    @Test func reads32BitFloatMono() throws {
        let wav = WavTestSupport.float32(
            interleaved: [0.0, 1.0, -1.0], channels: 1, sampleRate: 48000,
        )
        let result = try WavPcmReader.read(wav)
        #expect(result.samples == [0, 32767, -32767])
        #expect(result.sampleRate == 48000)
    }

    @Test func rejects24BitPcm() {
        let wav = WavTestSupport.pcm24(frames: 4, channels: 1, sampleRate: 44100)
        #expect(throws: MetronomeClickError.self) {
            _ = try WavPcmReader.read(wav)
        }
    }

    @Test func rejectsNonRiff() {
        let garbage = Data([
            0x00,
            0x01,
            0x02,
            0x03,
            0x04,
            0x05,
            0x06,
            0x07,
            0x08,
            0x09,
            0x0A,
            0x0B,
        ])
        #expect(throws: MetronomeClickError.self) {
            _ = try WavPcmReader.read(garbage)
        }
    }
}
