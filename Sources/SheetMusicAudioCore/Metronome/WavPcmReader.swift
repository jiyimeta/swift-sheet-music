import Foundation

/// Reads a PCM WAV container into mono `Int16` samples plus its sample rate.
///
/// Supported: 16-bit integer PCM (`audioFormat == 1`) and 32-bit IEEE
/// float (`audioFormat == 3`), mono or stereo. Stereo is down-mixed to
/// mono by averaging the channels. Anything else throws
/// `MetronomeClickError`.
///
/// Operates on raw `Data` so the Android JNI path can pass WAV bytes
/// directly (Android assets are not real file paths); a URL convenience
/// reads the file first.
public enum WavPcmReader {
    public struct Result: Equatable, Sendable {
        public let samples: [Int16]
        public let sampleRate: UInt32

        public init(samples: [Int16], sampleRate: UInt32) {
            self.samples = samples
            self.sampleRate = sampleRate
        }
    }

    public static func read(contentsOf url: URL) throws -> Result {
        try read(Data(contentsOf: url))
    }

    // swiftlint:disable:next function_body_length
    public static func read(_ data: Data) throws -> Result {
        let bytes = [UInt8](data)

        func u16(_ i: Int) -> UInt16 {
            UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
        }
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        }
        func tag(_ i: Int) -> String {
            String(bytes: bytes[i ..< i + 4], encoding: .ascii) ?? ""
        }

        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else {
            throw MetronomeClickError.invalidWav(reason: "missing RIFF/WAVE header")
        }

        var format: (
            audioFormat: UInt16,
            channels: UInt16,
            sampleRate: UInt32,
            bits: UInt16,
        )?
        var dataRange: Range<Int>?

        // Walk the chunk list after the 12-byte RIFF/WAVE header. Each
        // chunk is a 4-byte id + u32 size + payload, word-aligned (odd
        // sizes are padded by one byte).
        var i = 12
        while i + 8 <= bytes.count {
            let id = tag(i)
            let size = Int(u32(i + 4))
            let payloadStart = i + 8
            guard payloadStart + size <= bytes.count else { break }
            if id == "fmt ", size >= 16 {
                format = (
                    u16(payloadStart),
                    u16(payloadStart + 2),
                    u32(payloadStart + 4),
                    u16(payloadStart + 14),
                )
            } else if id == "data" {
                dataRange = payloadStart ..< (payloadStart + size)
            }
            i = payloadStart + size + (size & 1)
        }

        guard let f = format else {
            throw MetronomeClickError.invalidWav(reason: "no fmt chunk")
        }
        guard let range = dataRange else {
            throw MetronomeClickError.invalidWav(reason: "no data chunk")
        }
        let channels = Int(f.channels)
        guard channels == 1 || channels == 2 else {
            throw MetronomeClickError.unsupportedWavFormat(
                reason: "channel count \(channels) not supported",
            )
        }

        let payload = Array(bytes[range])
        switch (f.audioFormat, f.bits) {
        case (1, 16):
            return Result(
                samples: decode16(payload, channels: channels),
                sampleRate: f.sampleRate,
            )
        case (3, 32):
            return Result(
                samples: decodeFloat32(payload, channels: channels),
                sampleRate: f.sampleRate,
            )
        default:
            throw MetronomeClickError.unsupportedWavFormat(
                reason: "audioFormat \(f.audioFormat), \(f.bits)-bit not supported",
            )
        }
    }

    private static func decode16(_ p: [UInt8], channels: Int) -> [Int16] {
        let frameBytes = 2 * channels
        let frameCount = p.count / frameBytes
        var out = [Int16]()
        out.reserveCapacity(frameCount)
        func s16(_ i: Int) -> Int16 {
            Int16(bitPattern: UInt16(p[i]) | (UInt16(p[i + 1]) << 8))
        }
        for f in 0 ..< frameCount {
            let base = f * frameBytes
            if channels == 1 {
                out.append(s16(base))
            } else {
                let mixed = (Int(s16(base)) + Int(s16(base + 2))) / 2
                out.append(Int16(mixed))
            }
        }
        return out
    }

    private static func decodeFloat32(_ p: [UInt8], channels: Int) -> [Int16] {
        let frameBytes = 4 * channels
        let frameCount = p.count / frameBytes
        var out = [Int16]()
        out.reserveCapacity(frameCount)
        func f32(_ i: Int) -> Float {
            let bits = UInt32(p[i]) | (UInt32(p[i + 1]) << 8)
                | (UInt32(p[i + 2]) << 16) | (UInt32(p[i + 3]) << 24)
            return Float(bitPattern: bits)
        }
        func toI16(_ x: Float) -> Int16 {
            let clamped = max(-1.0, min(1.0, x))
            return Int16((clamped * 32767.0).rounded())
        }
        for f in 0 ..< frameCount {
            let base = f * frameBytes
            if channels == 1 {
                out.append(toI16(f32(base)))
            } else {
                out.append(toI16((f32(base) + f32(base + 4)) / 2))
            }
        }
        return out
    }
}
