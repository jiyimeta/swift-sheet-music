#if canImport(AVFoundation)
    import AVFoundation
#endif
import Foundation
@testable import SheetMusicAudioCore
import Testing

struct AIFFEncodingTests {
    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    @Test func int16StereoHeaderIsPlainAIFF() {
        let header = AIFFEncoding.header(
            options: PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo), frameCount: 10,
        )
        #expect(header.count == 54)
        #expect(Array(header[0 ..< 4]) == Array("FORM".utf8))
        #expect(uint32(header, at: 4) == 46 + 40)
        #expect(Array(header[8 ..< 16]) == Array("AIFFCOMM".utf8))
        #expect(uint32(header, at: 16) == 18)
        #expect(uint16(header, at: 20) == 2)
        #expect(uint32(header, at: 22) == 10)
        #expect(uint16(header, at: 26) == 16)
        #expect(Array(header[28 ..< 38]) == [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])
        #expect(Array(header[38 ..< 42]) == Array("SSND".utf8))
        #expect(uint32(header, at: 42) == 8 + 40)
        #expect(uint32(header, at: 46) == 0)
        #expect(uint32(header, at: 50) == 0)
    }

    @Test func float32HeaderIsAIFFCWithFl32() {
        let header = AIFFEncoding.header(
            options: PCMOptions(sampleRate: 48000, bitDepth: .float32, channels: .mono), frameCount: 3,
        )
        #expect(header.count == 92)
        #expect(Array(header[8 ..< 16]) == Array("AIFCFVER".utf8))
        #expect(uint32(header, at: 20) == 0xA280_5140)
        #expect(Array(header[24 ..< 28]) == Array("COMM".utf8))
        #expect(uint32(header, at: 28) == 44)
        #expect(uint16(header, at: 32) == 1)
        #expect(uint32(header, at: 34) == 3)
        #expect(uint16(header, at: 38) == 32)
        #expect(Array(header[50 ..< 54]) == Array("fl32".utf8))
        #expect(header[54] == 21)
        #expect(Array(header[55 ..< 76]) == Array("32-bit floating point".utf8))
        #expect(Array(header[76 ..< 80]) == Array("SSND".utf8))
        #expect(uint32(header, at: 80) == 8 + 12)
        #expect(uint32(header, at: 4) == UInt32(header.count - 8 + 12))
    }

    @Test func sampleRatesAreEightyBitExtended() {
        #expect(AIFFEncoding.extended(48000) == [0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])
        #expect(AIFFEncoding.extended(22050) == [0x40, 0x0D, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])
        #expect(AIFFEncoding.extended(96000) == [0x40, 0x0F, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])
    }

    @Test func samplesAreWAVsWithTheirBytesReversed() {
        let source: [Float] = [1, -1, 0.5, -0.25]
        for depth in [PCMBitDepth.int16, .int24, .int32, .float32] {
            let options = PCMOptions(bitDepth: depth)
            var little: [UInt8] = []
            var big: [UInt8] = []
            source.withUnsafeBufferPointer {
                WAVEncoding.appendSamples($0, frames: 2, options: options, to: &little)
                AIFFEncoding.appendSamples($0, frames: 2, options: options, to: &big)
            }
            let width = AIFFEncoding.bytesPerFrame(options) / 2
            let reversed = stride(from: 0, to: little.count, by: width).flatMap { little[$0 ..< $0 + width].reversed() }
            #expect(big == reversed, "\(depth)")
        }
    }

    @Test func appendingKeepsWhatWasThere() {
        var bytes: [UInt8] = [7, 7, 7]
        [Float(1), 1].withUnsafeBufferPointer {
            AIFFEncoding.appendSamples($0, frames: 1, options: PCMOptions(bitDepth: .int16), to: &bytes)
        }
        #expect(bytes == [7, 7, 7, 0x7F, 0xFF, 0x7F, 0xFF])
    }

    @Test func aHeaderPastFourGigabytesSaysTheMostAnAIFFCanHold() {
        let header = AIFFEncoding.header(options: PCMOptions(bitDepth: .int16), frameCount: 2_000_000_000)
        #expect(Int(uint32(header, at: 42)) == 8 + AIFFEncoding.maximumDataBytes)
        #expect(Int(uint32(header, at: 4)) == 46 + AIFFEncoding.maximumDataBytes)
    }

    #if canImport(AVFoundation)
        /// The bytes as CoreAudio reads them: what a user's other software makes of the file.
        @Test(arguments: [PCMBitDepth.int16, .int24, .float32])
        func coreAudioReadsTheFile(depth: PCMBitDepth) throws {
            let options = PCMOptions(sampleRate: 44100, bitDepth: depth, channels: .stereo)
            let source: [Float] = (0 ..< 200).map { Float(sin(Double($0) / 7)) * 0.5 }
            var bytes = AIFFEncoding.header(options: options, frameCount: 100)
            source.withUnsafeBufferPointer {
                AIFFEncoding.appendSamples($0, frames: 100, options: options, to: &bytes)
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(bytes).write(to: url)

            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            #expect(file.length == 100)
            #expect(file.fileFormat.sampleRate == 44100)
            #expect(file.fileFormat.channelCount == 2)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100))
            try file.read(into: buffer)
            let left = try #require(buffer.floatChannelData?[0])
            let right = try #require(buffer.floatChannelData?[1])
            let step: Float = depth == .int16 ? 1 / 32767 : 1e-6
            for frame in [0, 1, 37, 99] {
                #expect(abs(left[frame] - source[frame * 2]) <= step, "left \(frame)")
                #expect(abs(right[frame] - source[frame * 2 + 1]) <= step, "right \(frame)")
            }
        }
    #endif
}
