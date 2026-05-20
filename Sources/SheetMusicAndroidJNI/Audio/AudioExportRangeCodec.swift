import Foundation
import SheetMusicAudioCore
import SheetMusicCore

/// Codec for `AudioExportRange` — mirrors the Kotlin
/// `AudioExportRangeEncoder` wire format used by the audio export JNI
/// seam. The encoder lives on the Kotlin side (the host requests the
/// range); Swift only decodes here.
///
/// Wire layout:
/// ```
///   u16 version (= 1)
///   u8  tag    0=full, 1=currentLoop, 2=region, 3=regionThroughEnd
///   tag 0 / 1: (no payload)
///   tag 2: ScoreCursorPayload from + ScoreCursorPayload to
///   tag 3: ScoreCursorPayload from + ScoreItemIDPayload last
/// ```
public enum AudioExportRangeCodec {
    public enum DecodeError: Error, Equatable {
        case unknownTag(UInt8)
    }

    static let version: UInt16 = 1

    private static let tagFull: UInt8 = 0
    private static let tagCurrentLoop: UInt8 = 1
    private static let tagRegion: UInt8 = 2
    private static let tagRegionThroughEnd: UInt8 = 3

    public static func decode(_ data: Data) throws -> AudioExportRange {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        let tag = try r.readUInt8()
        switch tag {
        case tagFull:
            return .full
        case tagCurrentLoop:
            return .currentLoop
        case tagRegion:
            let from = try ScoreCursorCodec.decodePayload(&r)
            let to = try ScoreCursorCodec.decodePayload(&r)
            return .region(from: from, to: to)
        case tagRegionThroughEnd:
            let from = try ScoreCursorCodec.decodePayload(&r)
            let last = try ScoreItemIDCodec.decodePayload(&r)
            return .regionThroughEnd(from: from, last: last)
        default:
            throw DecodeError.unknownTag(tag)
        }
    }
}
