import Foundation
@testable import SheetMusicAudioWindows
import Testing

/// `MP4VideoWriter`: one second of frames whose top and bottom halves differ, with a second of silence, written and
/// read back through Media Foundation — the codecs, the size, the length, the row order (top-down input) — and the
/// colour: the values the stream holds, in the matrix a player assumes for its height, and the `colr` box that names
/// it, read from the container. Only where Media Foundation's encoders are installed (not on an "N" edition without the
/// Media Feature Pack).
@Suite(.enabled(if: MP4VideoWriter.isAvailable))
struct MP4VideoWriterTests {
    /// A frame size, and the matrix its frames are written in.
    struct Size: Sendable, CustomTestStringConvertible {
        let width: Int
        let height: Int
        /// ISO/IEC 23091-2's code for the matrix: 6 BT.601 (below 720 rows), 1 BT.709 (from 720).
        let matrix: UInt16

        var testDescription: String {
            "\(width) x \(height)"
        }

        /// The luma and chroma weights of red and blue in `matrix`.
        var weights: (red: Double, blue: Double) {
            matrix == 1 ? (0.2126, 0.0722) : (0.299, 0.114)
        }
    }

    private static let sd = Size(width: 320, height: 180, matrix: 6)
    /// The first height a player takes for HD, so the edge of the rule is what is tested.
    private static let hd = Size(width: 1280, height: 720, matrix: 1)
    private static let fps = 30
    /// The top half's colour and the bottom half's, as (blue, green, red).
    private static let top: (blue: UInt8, green: UInt8, red: UInt8) = (200, 120, 40)
    private static let bottom: (blue: UInt8, green: UInt8, red: UInt8) = (40, 60, 200)

    private static func frame(_ size: Size) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        for y in 0 ..< size.height {
            let color = y < size.height / 2 ? top : bottom
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                pixels[index] = color.blue
                pixels[index + 1] = color.green
                pixels[index + 2] = color.red
                pixels[index + 3] = 255
            }
        }
        return pixels
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ssm-mp4-\(UUID().uuidString).mp4")
    }

    private typealias Color = (blue: UInt8, green: UInt8, red: UInt8)

    /// `color` in `size`'s matrix, studio range — what the writer must put in the stream, worked out here in floating
    /// point from the standards' coefficients rather than from the writer's integer ones.
    private static func yuv(_ color: Color, in size: Size) -> (luma: Double, cb: Double, cr: Double) {
        let red = Double(color.red), green = Double(color.green), blue = Double(color.blue)
        let (kr, kb) = size.weights
        let luma = kr * red + (1 - kr - kb) * green + kb * blue
        return (
            16 + luma * 219 / 255,
            128 + (blue - luma) / (2 * (1 - kb)) * 224 / 255,
            128 + (red - luma) / (2 * (1 - kr)) * 224 / 255,
        )
    }

    private static func near(_ read: (luma: UInt8, cb: UInt8, cr: UInt8), _ wanted: Color, in size: Size) -> Bool {
        // H.264 at this rate keeps a flat colour within a level or two of what went in.
        let expected = yuv(wanted, in: size)
        let tolerance = 3.0
        return abs(Double(read.luma) - expected.luma) <= tolerance && abs(Double(read.cb) - expected.cb) <= tolerance
            && abs(Double(read.cr) - expected.cr) <= tolerance
    }

    @discardableResult
    private static func write(
        to url: URL, size: Size = sd, withAudio: Bool, rateControl: MP4VideoWriter.RateControl = .constantBitRate,
        seconds: Int = 1,
    ) throws -> MP4VideoWriter.AcceptedRateControl {
        let audio = withAudio ? MP4VideoWriter.Audio(sampleRate: 48000, channels: 2, bitRate: 128_000) : nil
        let writer = try MP4VideoWriter(
            url: url, width: size.width, height: size.height, fps: fps, videoBitRate: 2_000_000,
            rateControl: rateControl, audio: audio,
        )
        let accepted = writer.acceptedRateControl
        let pixels = frame(size)
        for _ in 0 ..< fps * seconds {
            try pixels.withUnsafeBytes { try writer.appendFrame($0) }
        }
        if withAudio {
            let block = 4800
            let silence = [Int16](repeating: 0, count: block * 2)
            for _ in 0 ..< 10 {
                try silence.withUnsafeBufferPointer { try writer.appendAudio($0, frames: block) }
            }
        }
        try writer.finish()
        return accepted
    }

    private static func size(of url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    @Test
    func `a second of H.264 and AAC reads back with its size and length`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, withAudio: true)
        let probe = try #require(MP4VideoWriter.probe(url))
        #expect(probe.videoIsH264)
        #expect(probe.audioIsAAC)
        #expect(probe.width == Self.sd.width && probe.height == Self.sd.height)
        #expect(abs(probe.durationSeconds - 1.0) < 0.1, "duration \(probe.durationSeconds) s")
    }

    /// What the stream holds, read without any decoder's colour conversion: each half's studio-range values in the
    /// matrix a player assumes for the height (BT.601 below 720 rows, BT.709 from 720), the top half on top. A
    /// decoder that converted to RGB would answer by whatever matrix it assumed instead.
    @Test(arguments: [sd, hd])
    func `the stream holds each half's values in the height's matrix, top half on top`(_ size: Size) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, size: size, withAudio: false)
        // A copy for another reader (folino checks one with ffprobe and AVFoundation on the Mac), when asked for.
        if let keep = ProcessInfo.processInfo.environment["SSM_KEEP_MP4_DIR"] {
            let kept = URL(fileURLWithPath: keep).appendingPathComponent("colours-\(size.height).mp4")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: url, to: kept)
        }
        let upper = try MP4VideoWriter.firstFrameYUV(url, x: size.width / 2, y: size.height / 4)
        let lower = try MP4VideoWriter.firstFrameYUV(url, x: size.width / 2, y: size.height * 3 / 4)
        #expect(Self.near(upper, Self.top, in: size), "top half read \(upper), wanted \(Self.yuv(Self.top, in: size))")
        #expect(
            Self.near(lower, Self.bottom, in: size),
            "bottom half read \(lower), wanted \(Self.yuv(Self.bottom, in: size))",
        )
    }

    /// The file names the matrix its frames are in, so a player that reads the tag decodes them right: Media
    /// Foundation's encoder writes no colour description into the stream (measured on folino-win, 2026-11-15), so the
    /// container's `colr` box is the tag. BT.709 primaries and transfer, studio range, at every size.
    @Test(arguments: [sd, hd])
    func `the colr box names the frames' matrix`(_ size: Size) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, size: size, withAudio: true)
        let colour = try #require(try MP4VideoWriter.colour(url), "no colr box")
        #expect(colour.matrix == size.matrix, "matrix \(colour.matrix)")
        #expect(colour.primaries == 1, "primaries \(colour.primaries)")
        #expect(colour.transfer == 1, "transfer \(colour.transfer)")
        #expect(!colour.fullRange)
        // The box grows the moov without moving the media: the file still plays its whole length.
        let probe = try #require(MP4VideoWriter.probe(url))
        #expect(abs(probe.durationSeconds - 1.0) < 0.1, "duration \(probe.durationSeconds) s")
    }

    /// Quality mode spends what a frame that barely changes needs, not the average bit rate: the same two seconds of a
    /// still frame come out smaller than at constant bit rate, read back whole, with the colours where they were. What
    /// the encoder took is reported, never "not asked"; on folino-qa's hardware encoder it is Quality mode itself.
    @Test(arguments: [sd, hd])
    func `quality mode writes a still frame smaller than constant bit rate, colours intact`(_ size: Size) throws {
        let constant = Self.temporaryURL()
        let quality = Self.temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: constant)
            try? FileManager.default.removeItem(at: quality)
        }
        let notAsked = try Self.write(to: constant, size: size, withAudio: false, seconds: 2)
        let accepted = try Self.write(
            to: quality, size: size, withAudio: false, rateControl: .quality(60), seconds: 2,
        )
        #expect(notAsked == .notAsked)
        #expect(accepted != .notAsked, "accepted \(accepted)")
        let constantBytes = try Self.size(of: constant), qualityBytes = try Self.size(of: quality)
        #expect(qualityBytes < constantBytes, "quality \(qualityBytes) B, constant \(constantBytes) B, \(accepted)")
        let probe = try #require(MP4VideoWriter.probe(quality))
        #expect(probe.videoIsH264)
        #expect(abs(probe.durationSeconds - 2.0) < 0.1, "duration \(probe.durationSeconds) s")
        let upper = try MP4VideoWriter.firstFrameYUV(quality, x: size.width / 2, y: size.height / 4)
        let lower = try MP4VideoWriter.firstFrameYUV(quality, x: size.width / 2, y: size.height * 3 / 4)
        #expect(Self.near(upper, Self.top, in: size), "top half read \(upper)")
        #expect(Self.near(lower, Self.bottom, in: size), "bottom half read \(lower)")
        let colour = try #require(try MP4VideoWriter.colour(quality), "no colr box")
        #expect(colour.matrix == size.matrix, "matrix \(colour.matrix)")
    }

    /// The quality asked for is clamped to 0–100 before it reaches the encoder.
    @Test
    func `a quality outside 0 to 100 is clamped`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let accepted = try Self.write(to: url, withAudio: false, rateControl: .quality(250))
        if case let .quality(took) = accepted {
            #expect((0 ... 100).contains(took), "took \(took)")
        }
        #expect(MP4VideoWriter.probe(url)?.videoIsH264 == true)
    }

    @Test
    func `a video without audio has no audio stream`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, withAudio: false)
        let probe = try #require(MP4VideoWriter.probe(url))
        #expect(probe.videoIsH264)
        #expect(!probe.audioIsAAC)
    }

    @Test
    func `an odd size and a short frame are refused`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: MP4VideoWriter.Failure.invalidSize(width: 321, height: 180)) {
            _ = try MP4VideoWriter(url: url, width: 321, height: 180, fps: 30, videoBitRate: 1_000_000, audio: nil)
        }
        let writer = try MP4VideoWriter(url: url, width: 64, height: 64, fps: 30, videoBitRate: 1_000_000, audio: nil)
        let short = [UInt8](repeating: 0, count: 64 * 64 * 4 - 4)
        #expect(throws: MP4VideoWriter.Failure.self) {
            try short.withUnsafeBytes { try writer.appendFrame($0) }
        }
        writer.abandon()
    }
}
