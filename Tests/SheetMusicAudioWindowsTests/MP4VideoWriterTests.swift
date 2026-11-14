import Foundation
@testable import SheetMusicAudioWindows
import Testing

/// `MP4VideoWriter`: one second of frames whose top and bottom halves differ, with a second of silence, written and
/// read back through Media Foundation — the codecs, the size, the length, the colours (the BT.709 tags) and the row
/// order (top-down input). Only where Media Foundation's encoders are installed (not on an "N" edition without the
/// Media Feature Pack).
@Suite(.enabled(if: MP4VideoWriter.isAvailable))
struct MP4VideoWriterTests {
    private static let width = 320
    private static let height = 180
    private static let fps = 30
    /// The top half's colour and the bottom half's, as (blue, green, red).
    private static let top: (blue: UInt8, green: UInt8, red: UInt8) = (200, 120, 40)
    private static let bottom: (blue: UInt8, green: UInt8, red: UInt8) = (40, 60, 200)

    private static func frame() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let color = y < height / 2 ? top : bottom
            for x in 0 ..< width {
                let index = (y * width + x) * 4
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

    /// `color` in BT.709, studio range — what the writer must put in the stream, worked out here in floating point
    /// from the standard's coefficients rather than from the writer's integer ones.
    private static func bt709(_ color: Color) -> (luma: Double, cb: Double, cr: Double) {
        let red = Double(color.red), green = Double(color.green), blue = Double(color.blue)
        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return (
            16 + luma * 219 / 255,
            128 + (blue - luma) / 1.8556 * 224 / 255,
            128 + (red - luma) / 1.5748 * 224 / 255,
        )
    }

    private static func near(_ read: (luma: UInt8, cb: UInt8, cr: UInt8), _ wanted: Color) -> Bool {
        // H.264 at this rate keeps a flat colour within a level or two of what went in.
        let expected = bt709(wanted)
        let tolerance = 3.0
        return abs(Double(read.luma) - expected.luma) <= tolerance && abs(Double(read.cb) - expected.cb) <= tolerance
            && abs(Double(read.cr) - expected.cr) <= tolerance
    }

    private static func write(to url: URL, withAudio: Bool) throws {
        let audio = withAudio ? MP4VideoWriter.Audio(sampleRate: 48000, channels: 2, bitRate: 128_000) : nil
        let writer = try MP4VideoWriter(
            url: url, width: width, height: height, fps: fps, videoBitRate: 2_000_000, audio: audio,
        )
        let pixels = frame()
        for _ in 0 ..< fps {
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
    }

    @Test
    func `a second of H.264 and AAC reads back with its size and length`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, withAudio: true)
        let probe = try #require(MP4VideoWriter.probe(url))
        #expect(probe.videoIsH264)
        #expect(probe.audioIsAAC)
        #expect(probe.width == Self.width && probe.height == Self.height)
        #expect(abs(probe.durationSeconds - 1.0) < 0.1, "duration \(probe.durationSeconds) s")
    }

    /// What the stream holds, read without any decoder's colour conversion: each half's BT.709 studio-range values,
    /// the top half on top. A decoder that converted to RGB would answer by whatever matrix it assumed instead.
    @Test
    func `the stream holds each half's BT.709 values, top half on top`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, withAudio: false)
        // A copy for another decoder to read (folino checks one with AVFoundation on the Mac), when asked for.
        if let keep = ProcessInfo.processInfo.environment["SSM_KEEP_MP4_DIR"] {
            let kept = URL(fileURLWithPath: keep).appendingPathComponent("colours.mp4")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: url, to: kept)
        }
        let upper = try MP4VideoWriter.firstFrameYUV(url, x: Self.width / 2, y: Self.height / 4)
        let lower = try MP4VideoWriter.firstFrameYUV(url, x: Self.width / 2, y: Self.height * 3 / 4)
        #expect(Self.near(upper, Self.top), "top half read \(upper), wanted \(Self.bt709(Self.top))")
        #expect(Self.near(lower, Self.bottom), "bottom half read \(lower), wanted \(Self.bt709(Self.bottom))")
    }

    /// The stream says it is BT.709, so a player reads it so: without the tag a player takes an SD stream for BT.601,
    /// and every colour comes back up to 24 levels off (folino-win's hardware encoder wrote none, 2026-11-15).
    @Test
    func `the stream says it is BT.709`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, withAudio: false)
        #expect(try MP4VideoWriter.videoMatrix(url) == 1, "MFVideoTransferMatrix_BT709")
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
