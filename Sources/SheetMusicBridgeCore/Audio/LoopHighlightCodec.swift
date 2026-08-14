import Foundation
import Wirelet

/// Wire format for the loop-region highlight rectangles. One rect per
/// intersected system, in mm coordinates.
///
/// The bytes are **wirelet TLV**, not a packed struct array: a
/// length-prefixed array of `Rect`, each entry itself length-prefixed
/// with a tag per field. Decode with the generated `RectCodec`, never by
/// reading raw doubles at a fixed stride.
///
/// Empty byte array signals "no rects" (loop range empty or
/// unresolved); the encoder always produces the full envelope for a
/// non-nil input, even when the input array is empty.
///
/// (This comment previously described an `i32 count` followed by packed
/// `f64`s at 32 bytes per rect — a description of neither the current
/// format nor the i64-micros one that preceded it. It was one of three
/// mutually inconsistent accounts of this payload; the Kotlin reader
/// that actually runs is the authority, and it reads TLV.)
public enum LoopHighlightCodec {
    @WireFormat
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
        rects.encodeToData()
    }

    public static func decode(_ data: Data) throws -> [Rect] {
        if data.isEmpty { return [] }
        return try [Rect](decoding: data)
    }
}
