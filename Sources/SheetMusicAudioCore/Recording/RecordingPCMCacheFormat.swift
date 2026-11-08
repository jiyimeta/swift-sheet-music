import SheetMusicFoundation

/// The one definition of a decoded recording's PCM cache file, which every platform's decoder writes
/// (`RecordingPCMCacheWriter`) and `MappedRecording` maps.
///
/// Layout, little-endian: `"SMPC"`, UInt32 version (1), UInt32 frame count, UInt32 sample rate in Hz, then
/// `frameCount × 2` Int16 samples, interleaved left and right — so the file is exactly `16 + 4 × frameCount` bytes. A
/// mono source is written with each sample on both channels. The file is named `<cacheKey>-<sample rate in whole
/// Hz>.pcm`, and its header is written last, so a file whose writer died has no magic and fails validation.
public enum RecordingPCMCacheFormat {
    package static let headerSize = 16
    package static let magic: [UInt8] = Array("SMPC".utf8)
    package static let version: UInt32 = 1

    /// The sample rate `sampleRate` is stored at — rounded to whole Hz — or nil when that is not finite or not within
    /// 1 … `UInt32.max`.
    public static func wholeHertz(_ sampleRate: Double) -> UInt32? {
        let rounded = sampleRate.rounded()
        guard rounded.isFinite, rounded >= 1, rounded <= Double(UInt32.max) else { return nil }
        return UInt32(rounded)
    }

    /// `<cacheKey>-<sample rate in whole Hz>.pcm`, or nil for a sample rate `wholeHertz(_:)` refuses.
    public static func fileName(cacheKey: String, sampleRate: Double) -> String? {
        wholeHertz(sampleRate).map { "\(cacheKey)-\($0).pcm" }
    }

    /// The header of a file of `frameCount` frames at `sampleRate`; nil when either does not fit the format (no frames,
    /// more than `UInt32.max`, or a sample rate `wholeHertz(_:)` refuses).
    package static func header(frameCount: Int, sampleRate: Double) -> [UInt8]? {
        guard frameCount > 0, UInt64(frameCount) <= UInt64(UInt32.max), let hertz = wholeHertz(sampleRate) else {
            return nil
        }
        var bytes = magic
        for value in [version, UInt32(frameCount), hertz] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    /// The frame count and sample rate a header holds, or nil when its magic or version is not this format's or its
    /// sample rate is 0.
    package static func parseHeader(_ header: [UInt8]) -> (frameCount: Int, sampleRate: UInt32)? {
        guard header.count >= headerSize, Array(header[0 ..< 4]) == magic, word(header, at: 4) == version else {
            return nil
        }
        let rate = word(header, at: 12)
        // `Int(exactly:)`: on a 32-bit platform (wasm) a frame count past `Int.max` is not a file it can map.
        guard rate > 0, let frames = Int(exactly: word(header, at: 8)) else { return nil }
        return (frames, rate)
    }

    /// The size of a complete file of `frameCount` frames.
    package static func fileSize(frameCount: Int) -> Int64 {
        Int64(headerSize) + Int64(frameCount) * 4
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
