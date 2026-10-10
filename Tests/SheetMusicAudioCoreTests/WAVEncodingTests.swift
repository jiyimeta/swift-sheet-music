import Foundation
@testable import SheetMusicAudioCore
import Testing

struct WAVEncodingTests {
    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset ..< offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func int16Samples(_ bytes: [UInt8]) -> [Int16] {
        stride(from: 0, to: bytes.count, by: 2).map { Int16(bitPattern: uint16(bytes, at: $0)) }
    }

    @Test func int16StereoHeaderIsTheCanonical44Bytes() {
        let header = WAVEncoding.header(
            options: PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo), frameCount: 10,
        )
        #expect(header.count == 44)
        #expect(Array(header[0 ..< 4]) == Array("RIFF".utf8))
        #expect(uint32(header, at: 4) == 36 + 40)
        #expect(Array(header[8 ..< 16]) == Array("WAVEfmt ".utf8))
        #expect(uint32(header, at: 16) == 16)
        #expect(uint16(header, at: 20) == 1) // WAVE_FORMAT_PCM
        #expect(uint16(header, at: 22) == 2)
        #expect(uint32(header, at: 24) == 44100)
        #expect(uint32(header, at: 28) == 44100 * 4)
        #expect(uint16(header, at: 32) == 4)
        #expect(uint16(header, at: 34) == 16)
        #expect(Array(header[36 ..< 40]) == Array("data".utf8))
        #expect(uint32(header, at: 40) == 40)
    }

    @Test func float32HeaderCarriesIEEEFloatAndAFactChunk() {
        let header = WAVEncoding.header(
            options: PCMOptions(sampleRate: 48000, bitDepth: .float32, channels: .mono), frameCount: 3,
        )
        #expect(header.count == 58)
        #expect(uint32(header, at: 16) == 18)
        #expect(uint16(header, at: 20) == 3) // WAVE_FORMAT_IEEE_FLOAT
        #expect(uint16(header, at: 36) == 0) // cbSize
        #expect(Array(header[38 ..< 42]) == Array("fact".utf8))
        #expect(uint32(header, at: 46) == 3)
        #expect(Array(header[50 ..< 54]) == Array("data".utf8))
        #expect(uint32(header, at: 54) == 12)
        #expect(uint32(header, at: 4) == 50 + 12)
    }

    @Test func int16SamplesClampAndRound() {
        let source: [Float] = [0, 1, -1, 2, 0.5, -0.5]
        var bytes: [UInt8] = []
        source.withUnsafeBufferPointer {
            WAVEncoding.appendSamples($0, frames: 3, options: PCMOptions(bitDepth: .int16), to: &bytes)
        }
        #expect(int16Samples(bytes) == [0, 32767, -32767, 32767, 16384, -16384])
    }

    @Test func monoIsTheMeanOfBothChannels() {
        let source: [Float] = [1, 0, -0.5, -0.5]
        var bytes: [UInt8] = []
        source.withUnsafeBufferPointer {
            WAVEncoding.appendSamples(
                $0, frames: 2, options: PCMOptions(bitDepth: .int16, channels: .mono), to: &bytes,
            )
        }
        #expect(int16Samples(bytes) == [16384, -16384])
    }

    @Test func int24AndInt32AreLittleEndianFullScale() {
        let source: [Float] = [1, -1]
        var bytes24: [UInt8] = []
        var bytes32: [UInt8] = []
        source.withUnsafeBufferPointer {
            WAVEncoding.appendSamples($0, frames: 1, options: PCMOptions(bitDepth: .int24), to: &bytes24)
            WAVEncoding.appendSamples($0, frames: 1, options: PCMOptions(bitDepth: .int32), to: &bytes32)
        }
        #expect(bytes24 == [0xFF, 0xFF, 0x7F, 0x01, 0x00, 0x80])
        #expect(uint32(bytes32, at: 0) == 0x7FFF_FFFF)
        #expect(uint32(bytes32, at: 4) == 0x8000_0001)
    }

    @Test func float32SamplesAreTheirBitPatterns() {
        let source: [Float] = [0.25, -2]
        var bytes: [UInt8] = []
        source.withUnsafeBufferPointer {
            WAVEncoding.appendSamples($0, frames: 1, options: PCMOptions(bitDepth: .float32), to: &bytes)
        }
        #expect(uint32(bytes, at: 0) == Float(0.25).bitPattern)
        #expect(uint32(bytes, at: 4) == Float(-1).bitPattern)
    }

    @Test func aHeaderPastFourGigabytesSaysTheMostAWAVCanHold() {
        let header = WAVEncoding.header(options: PCMOptions(bitDepth: .int16), frameCount: 2_000_000_000)
        #expect(Int(uint32(header, at: 40)) == WAVEncoding.maximumDataBytes)
        #expect(Int(uint32(header, at: 4)) == 36 + WAVEncoding.maximumDataBytes)
    }

    /// A frame count whose byte size does not fit an `Int` (on a 32-bit host, a few hours of audio) says the most a
    /// header can, rather than trapping.
    @Test func aByteCountPastIntSaturates() {
        #expect(WAVEncoding.byteCount(frames: Int.max / 2, bytesPerFrame: 4) == Int.max)
        #expect(WAVEncoding.byteCount(frames: 10, bytesPerFrame: 4) == 40)
        let header = WAVEncoding.header(options: PCMOptions(bitDepth: .float32), frameCount: Int.max / 2)
        #expect(Int(uint32(header, at: 54)) == WAVEncoding.maximumDataBytes)
    }

    @Test func bytesPerFrameFollowsDepthAndChannels() {
        #expect(WAVEncoding.bytesPerFrame(PCMOptions(bitDepth: .int16, channels: .stereo)) == 4)
        #expect(WAVEncoding.bytesPerFrame(PCMOptions(bitDepth: .int24, channels: .mono)) == 3)
        #expect(WAVEncoding.bytesPerFrame(PCMOptions(bitDepth: .float32, channels: .stereo)) == 8)
    }
}
