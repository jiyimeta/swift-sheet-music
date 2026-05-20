import Foundation

/// Wire format for the loop-region highlight rectangles. One rect per
/// intersected system, in mm coordinates.
///
/// Bytes layout:
/// ```
///   u16 version (= 1)
///   i32 count
///   count × {
///     i64 xMicros        // mm * 1e6
///     i64 yMicros
///     i64 widthMicros
///     i64 heightMicros
///   }
/// ```
///
/// Empty byte array signals "no rects" (loop range empty or unresolved).
public enum LoopHighlightCodec {
    public static let formatVersion: UInt16 = 1

    public struct Rect: Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public static func encode(_ rects: [Rect]) -> Data {
        var w = AudioBinaryWriter()
        w.append(formatVersion)
        w.append(Int32(rects.count))
        for r in rects {
            w.append(Int64((r.x * 1_000_000).rounded()))
            w.append(Int64((r.y * 1_000_000).rounded()))
            w.append(Int64((r.width * 1_000_000).rounded()))
            w.append(Int64((r.height * 1_000_000).rounded()))
        }
        return w.data
    }

    public static func decode(_ data: Data) throws -> [Rect] {
        if data.isEmpty { return [] }
        var r = AudioBinaryReader(data)
        try r.assertVersion(formatVersion)
        let count = try Int(r.readInt32())
        var out: [Rect] = []
        out.reserveCapacity(count)
        for _ in 0 ..< count {
            let x = try Double(r.readInt64()) / 1_000_000
            let y = try Double(r.readInt64()) / 1_000_000
            let wd = try Double(r.readInt64()) / 1_000_000
            let ht = try Double(r.readInt64()) / 1_000_000
            out.append(Rect(x: x, y: y, width: wd, height: ht))
        }
        return out
    }
}
