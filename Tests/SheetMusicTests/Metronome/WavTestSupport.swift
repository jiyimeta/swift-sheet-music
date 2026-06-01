import Foundation

/// Builds a PCM WAV container in memory for the reader tests, so we don't
/// commit binary fixtures. Writes little-endian, as the WAV spec requires.
enum WavTestSupport {
    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ]
    }

    /// Wrap `fmt` + `data` payloads in a RIFF/WAVE container.
    private static func riff(fmt: [UInt8], data: [UInt8]) -> Data {
        var body: [UInt8] = Array("WAVE".utf8)
        body += Array("fmt ".utf8) + u32(UInt32(fmt.count)) + fmt
        body += Array("data".utf8) + u32(UInt32(data.count)) + data
        let out: [UInt8] = Array("RIFF".utf8) + u32(UInt32(body.count)) + body
        return Data(out)
    }

    private static func fmtChunk(
        audioFormat: UInt16, channels: UInt16, sampleRate: UInt32, bits: UInt16,
    ) -> [UInt8] {
        let blockAlign = channels * (bits / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        return u16(audioFormat) + u16(channels) + u32(sampleRate)
            + u32(byteRate) + u16(blockAlign) + u16(bits)
    }

    /// 16-bit integer PCM WAV. `interleaved` is the raw per-channel sample
    /// stream (length = frames * channels).
    static func pcm16(interleaved: [Int16], channels: UInt16, sampleRate: UInt32) -> Data {
        var data: [UInt8] = []
        for s in interleaved {
            data += u16(UInt16(bitPattern: s))
        }
        return riff(
            fmt: fmtChunk(audioFormat: 1, channels: channels, sampleRate: sampleRate, bits: 16),
            data: data,
        )
    }

    /// 32-bit IEEE float WAV.
    static func float32(interleaved: [Float], channels: UInt16, sampleRate: UInt32) -> Data {
        var data: [UInt8] = []
        for s in interleaved {
            data += u32(s.bitPattern)
        }
        return riff(
            fmt: fmtChunk(audioFormat: 3, channels: channels, sampleRate: sampleRate, bits: 32),
            data: data,
        )
    }

    /// 24-bit PCM WAV (unsupported on purpose — for the rejection test).
    static func pcm24(frames: Int, channels: UInt16, sampleRate: UInt32) -> Data {
        let data = [UInt8](repeating: 0, count: frames * Int(channels) * 3)
        return riff(
            fmt: fmtChunk(audioFormat: 1, channels: channels, sampleRate: sampleRate, bits: 24),
            data: data,
        )
    }
}
