import Foundation

/// Container + codec selection for audio file export.
///
/// Each case carries its codec-specific options. Bare construction
/// — `.wav()`, `.aiff()`, `.m4a()`, `.mp3()` — uses the default
/// options struct. Bind a SwiftUI `Picker` to a separate tag enum
/// (see `SheetMusicAudio` README) since associated-value enums
/// don't play well with `Picker`.
public enum AudioFileFormat: Sendable {
    case wav(PCMOptions = .init())
    case aiff(PCMOptions = .init())
    case m4a(CompressedOptions = .init())
    case mp3(CompressedOptions = .init())
}

/// Sample resolution for PCM formats (WAV / AIFF).
public enum PCMBitDepth: Sendable, CaseIterable {
    case int16, int24, int32, float32
}

/// 1 = mono, 2 = stereo. Surround is out of scope.
public enum AudioChannelCount: Int, Sendable, CaseIterable {
    case mono = 1
    case stereo = 2
}

public struct PCMOptions: Sendable, Equatable {
    public var sampleRate: Double
    public var bitDepth: PCMBitDepth
    public var channels: AudioChannelCount

    public init(
        sampleRate: Double = 44100,
        bitDepth: PCMBitDepth = .int16,
        channels: AudioChannelCount = .stereo,
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }
}

public struct CompressedOptions: Sendable, Equatable {
    public var sampleRate: Double
    /// Bits per second. `192_000` is "transparent" AAC; `128_000`
    /// is a common smaller-file default.
    public var bitRate: Int
    public var channels: AudioChannelCount

    public init(
        sampleRate: Double = 44100,
        bitRate: Int = 192_000,
        channels: AudioChannelCount = .stereo,
    ) {
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.channels = channels
    }
}
