import Foundation
import SheetMusicAudioCore

/// Codec for `[MetronomeBeat]` — a top-level versioned array blob.
///
/// `MetronomeBeat` has `tick: Int` and `isDownbeat: Bool`. The wire
/// format stores a 32-bit kind field using this mapping:
/// ```
///   0  downbeat  (isDownbeat == true)
///   1  upbeat    (isDownbeat == false)
/// ```
/// The plan's `Kind.subdivision` case has no counterpart in the current
/// `MetronomeBeat` model, which only distinguishes downbeat/upbeat via
/// the `isDownbeat` flag. If a subdivision kind is introduced later,
/// the mapping should be extended here and in the Kotlin decoder.
///
/// Wire layout:
/// ```
/// MetronomeBeatArray
///   u16 version (= 1)
///   i32 count
///   count × { i64 tick; i32 kind; i32 _reserved }     16 bytes per entry
/// ```
public enum MetronomeBeatCodec {
    static let version: UInt16 = 1

    private static let kindDownbeat: Int32 = 0
    private static let kindUpbeat: Int32 = 1

    public static func encodeArray(_ beats: [MetronomeBeat]) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        w.append(Int32(beats.count))
        for beat in beats {
            w.append(Int64(beat.tick))
            w.append(beat.isDownbeat ? kindDownbeat : kindUpbeat)
            w.append(Int32(0)) // _reserved
        }
        return w.data
    }

    public static func decodeArray(_ data: Data) throws -> [MetronomeBeat] {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        let count = try Int(r.readInt32())
        var result: [MetronomeBeat] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            let tick = try Int(r.readInt64())
            let kind = try r.readInt32()
            _ = try r.readInt32() // _reserved
            let isDownbeat = kind == kindDownbeat
            result.append(MetronomeBeat(tick: tick, isDownbeat: isDownbeat))
        }
        return result
    }
}
