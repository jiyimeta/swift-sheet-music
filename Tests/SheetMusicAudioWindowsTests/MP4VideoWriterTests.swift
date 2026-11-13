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

    private static func near(_ read: Color, _ wanted: Color) -> Bool {
        // H.264 at this rate keeps a flat colour within a few levels once the tags say how to read it back.
        let tolerance = 8
        return abs(Int(read.blue) - Int(wanted.blue)) <= tolerance
            && abs(Int(read.green) - Int(wanted.green)) <= tolerance
            && abs(Int(read.red) - Int(wanted.red)) <= tolerance
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

    @Test
    func `the colours come back as written, top half on top`() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, withAudio: false)
        // A copy for another decoder to read (folino checks one with AVFoundation on the Mac), when asked for.
        if let keep = ProcessInfo.processInfo.environment["SSM_KEEP_MP4_DIR"] {
            let kept = URL(fileURLWithPath: keep).appendingPathComponent("colours.mp4")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: url, to: kept)
        }
        let upper = try MP4VideoWriter.firstFramePixel(url, x: Self.width / 2, y: Self.height / 4)
        let lower = try MP4VideoWriter.firstFramePixel(url, x: Self.width / 2, y: Self.height * 3 / 4)
        #expect(Self.near(upper, Self.top), "top half read \(upper), wrote \(Self.top)")
        #expect(Self.near(lower, Self.bottom), "bottom half read \(lower), wrote \(Self.bottom)")
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
