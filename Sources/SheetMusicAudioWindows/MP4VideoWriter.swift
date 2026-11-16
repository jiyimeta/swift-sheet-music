import CMediaFoundation
import Foundation

/// An MP4 file of H.264 video and AAC audio through Media Foundation (`CMediaFoundation`): what a host's score video is
/// written with on Windows. Frames go in as BGRA with rows top-down (`Direct2DFrameCanvas`'s pixels); audio as
/// interleaved 16-bit PCM. Each stream's times come from what has been written, frame by frame and sample by sample,
/// so a long video does not drift.
///
/// Media Foundation is loaded at run time, never linked, so a Windows "N" edition without the Media Feature Pack still
/// starts the host; there `isAvailable` is false and `init` throws `Failure.unavailable`. The frames are written in
/// studio range in the matrix a player assumes for an untagged stream of their height — BT.601 below 720 rows, BT.709
/// from 720 — and named in the file's `colr` box, since Media Foundation's encoders write no colour description into
/// the stream. Apple's writer tags BT.709 at every size in the stream itself.
///
/// Do not align this with Apple's always-BT.709: the difference is rooted in Windows alone. Media Foundation cannot
/// write the stream's colour description, so a player that ignores `colr` guesses by height, and BT.709 SD is then off.
///
/// Used from one thread: the one that made it (`init` joins the multithreaded COM apartment there).
public final class MP4VideoWriter {
    public struct Audio: Sendable, Equatable {
        public var sampleRate: Int
        public var channels: Int
        /// Bits per second; Microsoft's AAC encoder takes 96 000, 128 000, 160 000 or 192 000.
        public var bitRate: Int

        public init(sampleRate: Int, channels: Int, bitRate: Int) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitRate = bitRate
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No Media Foundation, or no H.264 or AAC encoder, on this Windows.
        case unavailable
        /// A frame size H.264 cannot take: empty or odd.
        case invalidSize(width: Int, height: Int)
        /// A frame of the wrong length, or audio handed to a writer without an audio stream.
        case invalidInput(String)
        case mediaFoundation(step: String, hresult: Int32)

        public var description: String {
            switch self {
            case .unavailable: "Media Foundation's H.264 / AAC encoders are not available on this Windows"
            case let .invalidSize(width, height): "a \(width) x \(height) frame (H.264 needs an even, non-empty size)"
            case let .invalidInput(what): what
            case let .mediaFoundation(step, hresult):
                "Media Foundation \(step) failed (HRESULT 0x\(Self.hex(hresult)))"
            }
        }

        private static func hex(_ hresult: Int32) -> String {
            String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)
        }
    }

    /// How the H.264 stream spends its bits. Windows only, like this writer: the package declares
    /// `SheetMusicAudioWindows` on Windows alone and writes no video elsewhere — Apple hosts use AVAssetWriter, whose
    /// average bit rate already behaves this way, and Android and WebAssembly have no video writer here.
    public enum RateControl: Sendable, Equatable {
        /// The encoder's defaults: constant bit rate at `videoBitRate`, Baseline profile. A score video, which barely
        /// changes from frame to frame, comes out about five times the size Apple's writer makes of it.
        case constantBitRate
        /// Quality mode at 0–100, High profile, a key frame every half second — what Apple's AVAssetWriter does with
        /// the same average bit rate, which it treats as a ceiling. An encoder that will not take Quality mode is asked
        /// for unconstrained VBR with `videoBitRate` as its mean, and failing that keeps its default
        /// (`acceptedRateControl` says which).
        case quality(Int)
    }

    /// The rate control the encoder took, read back once it was in the stream.
    public enum AcceptedRateControl: Sendable, Equatable {
        /// `.constantBitRate` was asked for: the encoder runs its defaults, not asked again.
        case notAsked
        case quality(Int)
        case unconstrainedVBR
        /// The encoder kept a mode of its own (an `eAVEncCommonRateControlMode`; 0 is CBR).
        case encoderMode(Int)
        /// The encoder could not be asked; it writes at its default.
        case unknown
    }

    /// What `probe(_:)` reads back from a file.
    public struct Probe: Sendable, Equatable {
        public var durationSeconds: Double
        public var width: Int
        public var height: Int
        public var videoIsH264: Bool
        public var audioIsAAC: Bool
    }

    /// Whether this Windows can write the MP4 — Media Foundation present with an H.264 and an AAC encoder. Asked once:
    /// installing the Media Feature Pack takes a restart, so the answer holds for the process.
    public static let isAvailable = cmf_mp4_encoder_available() == 1

    public let width: Int
    public let height: Int
    public let fps: Int
    public let audio: Audio?
    public let rateControl: RateControl
    /// What the encoder took for `rateControl`, read when the writer opened.
    public private(set) var acceptedRateControl: AcceptedRateControl = .notAsked
    private var writer: OpaquePointer?

    /// Opens `url` (replaced if it exists) for `width` x `height` frames at `fps`, H.264 at `videoBitRate` bits per
    /// second spent as `rateControl` says, and an AAC stream when `audio` is given.
    public init(
        url: URL, width: Int, height: Int, fps: Int, videoBitRate: Int, rateControl: RateControl = .constantBitRate,
        audio: Audio?,
    ) throws {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw Failure.invalidSize(width: width, height: height)
        }
        // Media Foundation present but without an H.264 encoder would fail inside `open` with some other HRESULT.
        guard Self.isAvailable else { throw Failure.unavailable }
        self.width = width
        self.height = height
        self.fps = fps
        self.audio = audio
        self.rateControl = rateControl
        let quality: Int32 = switch rateControl {
        case .constantBitRate: -1
        case let .quality(value): Int32(min(max(value, 0), 100))
        }
        var opened: OpaquePointer?
        var result = Self.open(url, width, height, fps, videoBitRate, quality, audio, &opened)
        // An encoder that refuses the High profile or the Quality parameters fails the stream's setup itself: the file
        // is then written as before, at the encoder's defaults, rather than not at all.
        if result != 0, result != Self.notImplemented, quality >= 0 {
            result = Self.open(url, width, height, fps, videoBitRate, -1, audio, &opened)
            if result == 0 { acceptedRateControl = .unknown }
        } else if result == 0, quality >= 0, let opened {
            var mode: Int32 = -1, took: Int32 = -1
            _ = cmf_mp4_rate_control(opened, &mode, &took)
            acceptedRateControl = switch mode {
            case 3: .quality(Int(took))
            case 2: .unconstrainedVBR
            case ..<0: .unknown
            default: .encoderMode(Int(mode))
            }
        }
        guard result == 0, let opened else {
            if result == Self.notImplemented { throw Failure.unavailable }
            throw Failure.mediaFoundation(step: "open", hresult: result)
        }
        writer = opened
    }

    // swiftlint:disable:next function_parameter_count
    private static func open(
        _ url: URL, _ width: Int, _ height: Int, _ fps: Int, _ videoBitRate: Int, _ quality: Int32, _ audio: Audio?,
        _ opened: inout OpaquePointer?,
    ) -> Int32 {
        url.path.withCString(encodedAs: UTF16.self) { path in
            cmf_mp4_open(
                path, UInt32(width), UInt32(height), UInt32(fps), UInt32(videoBitRate), quality,
                UInt32(audio?.sampleRate ?? 0), UInt32(audio?.channels ?? 0), UInt32(audio?.bitRate ?? 0), &opened,
            )
        }
    }

    deinit {
        cmf_mp4_close(writer)
    }

    /// The next frame: `width * height * 4` bytes of BGRA, rows top-down.
    public func appendFrame(_ bgra: UnsafeRawBufferPointer) throws {
        guard let writer else { throw Failure.invalidInput("the writer is finished") }
        let expected = width * height * 4
        guard bgra.count == expected, let base = bgra.baseAddress else {
            throw Failure.invalidInput("a frame of \(bgra.count) bytes where \(expected) were expected")
        }
        let result = cmf_mp4_write_frame(writer, base.assumingMemoryBound(to: UInt8.self))
        guard result == 0 else { throw Failure.mediaFoundation(step: "write frame", hresult: result) }
    }

    /// `frames` frames of interleaved 16-bit PCM, `audio.channels` samples each, after those appended so far.
    public func appendAudio(_ samples: UnsafeBufferPointer<Int16>, frames: Int) throws {
        guard let writer else { throw Failure.invalidInput("the writer is finished") }
        guard let audio else { throw Failure.invalidInput("audio for a writer opened without an audio stream") }
        guard samples.count >= frames * audio.channels, let base = samples.baseAddress else {
            throw Failure.invalidInput("\(samples.count) samples for \(frames) frames of \(audio.channels) channels")
        }
        let result = cmf_mp4_write_audio(writer, base, UInt32(frames))
        guard result == 0 else { throw Failure.mediaFoundation(step: "write audio", hresult: result) }
    }

    /// Where the frames' time has gone so far, and the H.264 encoder Media Foundation chose (read after the first
    /// frame). Before `finish()`; nil after it.
    public struct Stats: Sendable, Equatable {
        /// Seconds converting the BGRA frames to the encoder's NV12, summed.
        public var conversionSeconds: Double
        /// Seconds handing the frames to the Sink Writer, whose WriteSample encodes them, summed.
        public var writeSampleSeconds: Double
        /// The encoder MFT's friendly name; empty when it gives none or none was read yet.
        public var encoderName: String
        /// true for a hardware MFT, false for a software one, nil when not known.
        public var encoderIsHardware: Bool?
    }

    public var stats: Stats? {
        guard let writer else { return nil }
        var conversion = 0.0
        var write = 0.0
        var hardware: Int32 = -1
        var name = [UInt16](repeating: 0, count: 128)
        _ = name.withUnsafeMutableBufferPointer {
            cmf_mp4_stats(writer, &conversion, &write, $0.baseAddress, UInt32($0.count), &hardware)
        }
        let length = name.firstIndex(of: 0) ?? name.count
        return Stats(
            conversionSeconds: conversion, writeSampleSeconds: write,
            encoderName: String(decoding: name[..<length], as: UTF16.self),
            encoderIsHardware: hardware < 0 ? nil : hardware == 1,
        )
    }

    /// Completes the file, names its colour in a `colr` box, and lets go of the writer. A file whose layout left no
    /// room for the box (S_FALSE) is still complete; its colours are then right for players that go by its height.
    public func finish() throws {
        guard let writer else { return }
        let result = cmf_mp4_finish(writer)
        cmf_mp4_close(writer)
        self.writer = nil
        guard result >= 0 else { throw Failure.mediaFoundation(step: "finalize", hresult: result) }
    }

    /// Lets go of the writer without completing the file, which the caller then deletes (a cancelled export).
    public func abandon() {
        cmf_mp4_close(writer)
        writer = nil
    }

    /// What the file at `url` holds, read back through Media Foundation, or nil when it cannot be read.
    public static func probe(_ url: URL) -> Probe? {
        var duration: Int64 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var isH264: Int32 = 0
        var isAAC: Int32 = 0
        let result = url.path.withCString(encodedAs: UTF16.self) {
            cmf_mp4_probe($0, &duration, &width, &height, &isH264, &isAAC)
        }
        guard result == 0 else { return nil }
        return Probe(
            durationSeconds: Double(duration) / 10_000_000, width: Int(width), height: Int(height),
            videoIsH264: isH264 == 1, audioIsAAC: isAAC == 1,
        )
    }

    /// The file's first frame decoded by Media Foundation, at (`x`, `y`) from the top-left: (blue, green, red). What a
    /// test checks the colour tags and the row order with; throws the read's HRESULT when it cannot read it.
    package static func firstFramePixel(_ url: URL, x: Int, y: Int) throws -> (blue: UInt8, green: UInt8, red: UInt8) {
        var bgra = [UInt8](repeating: 0, count: 4)
        let result = url.path.withCString(encodedAs: UTF16.self) { path in
            bgra.withUnsafeMutableBufferPointer {
                cmf_mp4_first_frame_pixel(path, UInt32(x), UInt32(y), $0.baseAddress)
            }
        }
        guard result == 0 else { throw Failure.mediaFoundation(step: "read back the first frame", hresult: result) }
        return (bgra[0], bgra[1], bgra[2])
    }

    /// The file's first frame decoded to NV12 with no colour conversion, at (`x`, `y`) from the top-left: what the
    /// stream holds, whichever matrix a decoder would assume. What a test checks the writer's conversion with.
    package static func firstFrameYUV(_ url: URL, x: Int, y: Int) throws -> (luma: UInt8, cb: UInt8, cr: UInt8) {
        var yuv = [UInt8](repeating: 0, count: 3)
        let result = url.path.withCString(encodedAs: UTF16.self) { path in
            yuv.withUnsafeMutableBufferPointer { cmf_mp4_first_frame_yuv(path, UInt32(x), UInt32(y), $0.baseAddress) }
        }
        guard result == 0 else { throw Failure.mediaFoundation(step: "read back the first frame", hresult: result) }
        return (yuv[0], yuv[1], yuv[2])
    }

    /// The colour the file's `colr` box names, read from the container (ISO/IEC 23091-2 codes: 1 BT.709, 6 BT.601), or
    /// nil when it has none. What a test checks the tag with — the box itself, not what a decoder makes of it.
    package static func colour(
        _ url: URL,
    ) throws -> (primaries: UInt16, transfer: UInt16, matrix: UInt16, fullRange: Bool)? {
        var primaries: UInt16 = 0, transfer: UInt16 = 0, matrix: UInt16 = 0
        var fullRange: UInt8 = 0
        let result = url.path.withCString(encodedAs: UTF16.self) {
            cmf_mp4_colour($0, &primaries, &transfer, &matrix, &fullRange)
        }
        guard result >= 0 else { throw Failure.mediaFoundation(step: "read the colr box", hresult: result) }
        return result == 0 ? (primaries, transfer, matrix, fullRange != 0) : nil
    }

    /// E_NOTIMPL, what `cmf_mp4_open` answers when Media Foundation could not be loaded.
    private static let notImplemented = Int32(bitPattern: 0x8000_4001)
}
