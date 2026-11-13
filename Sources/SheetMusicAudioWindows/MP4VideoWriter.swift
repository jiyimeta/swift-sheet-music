import CMediaFoundation
import Foundation

/// An MP4 file of H.264 video and AAC audio through Media Foundation (`CMediaFoundation`): what a host's score video is
/// written with on Windows. Frames go in as BGRA with rows top-down (`Direct2DFrameCanvas`'s pixels); audio as
/// interleaved 16-bit PCM. Each stream's times come from what has been written, frame by frame and sample by sample,
/// so a long video does not drift.
///
/// Media Foundation is loaded at run time, never linked, so a Windows "N" edition without the Media Feature Pack still
/// starts the host; there `isAvailable` is false and `init` throws `Failure.unavailable`. The video stream is tagged
/// BT.709, studio range, as Apple's writer tags its own.
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
    private var writer: OpaquePointer?

    /// Opens `url` (replaced if it exists) for `width` x `height` frames at `fps`, H.264 at `videoBitRate` bits per
    /// second, and an AAC stream when `audio` is given.
    public init(url: URL, width: Int, height: Int, fps: Int, videoBitRate: Int, audio: Audio?) throws {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw Failure.invalidSize(width: width, height: height)
        }
        // Media Foundation present but without an H.264 encoder would fail inside `open` with some other HRESULT.
        guard Self.isAvailable else { throw Failure.unavailable }
        self.width = width
        self.height = height
        self.fps = fps
        self.audio = audio
        var opened: OpaquePointer?
        let result = url.path.withCString(encodedAs: UTF16.self) { path in
            cmf_mp4_open(
                path, UInt32(width), UInt32(height), UInt32(fps), UInt32(videoBitRate),
                UInt32(audio?.sampleRate ?? 0), UInt32(audio?.channels ?? 0), UInt32(audio?.bitRate ?? 0), &opened,
            )
        }
        guard result == 0, let opened else {
            if result == Self.notImplemented { throw Failure.unavailable }
            throw Failure.mediaFoundation(step: "open", hresult: result)
        }
        writer = opened
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

    /// Completes the file and lets go of the writer.
    public func finish() throws {
        guard let writer else { return }
        let result = cmf_mp4_finish(writer)
        cmf_mp4_close(writer)
        self.writer = nil
        guard result == 0 else { throw Failure.mediaFoundation(step: "finalize", hresult: result) }
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

    /// E_NOTIMPL, what `cmf_mp4_open` answers when Media Foundation could not be loaded.
    private static let notImplemented = Int32(bitPattern: 0x8000_4001)
}
