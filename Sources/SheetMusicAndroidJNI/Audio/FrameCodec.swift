import Foundation
import SheetMusicAudioCore
import SheetMusicCore

/// Codec for `PlaybackTimeline.Frame` — a top-level versioned blob.
///
/// Wire layout:
/// ```
/// Frame
///   u16 version (= 1)
///   i64 tick
///   i64 timeSecondsMicros    (round(timeSeconds * 1e6) as Int64)
///   ScoreCursorPayload       (inline — no inner version byte)
/// ```
public enum FrameCodec {
    static let version: UInt16 = 1

    public static func encode(_ value: PlaybackTimeline.Frame) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        w.append(Int64(value.tick))
        let micros = Int64((value.timeSeconds * 1_000_000).rounded())
        w.append(micros)
        ScoreCursorCodec.encodePayload(value.cursor, into: &w)
        return w.data
    }

    public static func decode(_ data: Data) throws -> PlaybackTimeline.Frame {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        let tick = try Int(r.readInt64())
        let micros = try r.readInt64()
        let timeSeconds = Double(micros) / 1_000_000.0
        let cursor = try ScoreCursorCodec.decodePayload(&r)
        return PlaybackTimeline.Frame(
            tick: tick,
            timeSeconds: timeSeconds,
            cursor: cursor,
        )
    }
}
