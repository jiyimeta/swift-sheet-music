import Foundation
import SheetMusicCore
import Wirelet

/// Codec for a selection tint payload — the color plus the (already-expanded, see `SelectionExpansion`'s doc
/// comment) set of `ScoreItemID`s it covers. This is the wire shape a future JNI entry point hands across the
/// boundary before calling `LayoutBridge.buildCommands(layout:tint:)`, whose `tint` parameter is the same
/// `(argb: UInt32, ids: Set<ScoreItemID>)` pair, just serialized.
///
/// Wire layout (Wirelet's TLV scheme — see `EditIntentCodec.swift`'s doc comment for the tag-and-varint format
/// this describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: argb   u32, varint — packed ARGB (0xAARRGGBB), matching DrawCommand.setColor's own field.
/// tag 2: items  [ScoreItemIDWire] — length-delimited array; see ScoreItemIDCodec.swift's doc comment for
///               each element's own encoding.
/// ```
public enum SelectionTintCodec {
    public static func encode(argb: UInt32, ids: Set<ScoreItemID>) -> Data {
        SelectionTintWire(
            argb: argb,
            items: ids.map(ScoreItemIDWire.init(from:)),
        ).encodeToData()
    }

    public static func decode(_ data: Data) throws -> (argb: UInt32, ids: Set<ScoreItemID>) {
        let wire = try SelectionTintWire(decoding: data)
        return (argb: wire.argb, ids: Set(wire.items.map { $0.decoded() }))
    }
}

@WireFormat
struct SelectionTintWire {
    var argb: UInt32
    var items: [ScoreItemIDWire]
}

/// Codec for the editing caret's bounding rect — millimetres throughout, since this wire type only ever
/// carries a value already converted at the JNI boundary (`nativeEditingCaretFrame`); unlike
/// `CursorFrameCodec` (unit-agnostic, used for both pt-space host calls and mm-space JNI calls), there is no
/// non-JNI caller for this one.
///
/// Wire layout (Wirelet's TLV scheme — see `EditIntentCodec.swift`'s doc comment for the tag-and-varint format
/// this describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: xMm       f64, varint
/// tag 2: yMm       f64, varint
/// tag 3: widthMm   f64, varint
/// tag 4: heightMm  f64, varint
/// ```
public enum EditCaretFrameCodec {
    public static func encode(xMm: Double, yMm: Double, widthMm: Double, heightMm: Double) -> Data {
        EditCaretFrameWire(xMm: xMm, yMm: yMm, widthMm: widthMm, heightMm: heightMm).encodeToData()
    }

    public static func decode(_ data: Data) throws -> EditCaretFrameWire {
        try EditCaretFrameWire(decoding: data)
    }
}

@WireFormat
public struct EditCaretFrameWire: Equatable {
    public var xMm: Double
    public var yMm: Double
    public var widthMm: Double
    public var heightMm: Double
}
