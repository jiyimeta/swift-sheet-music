import SheetMusicCore
import SheetMusicFoundation
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
/// tag 1: argb             u32, varint — packed ARGB (0xAARRGGBB), matching DrawCommand.setColor's own field.
/// tag 2: items            [ScoreItemIDWire] — length-delimited array; see ScoreItemIDCodec.swift's doc comment for
///                         each element's own encoding.
/// tag 3: creditFieldCode  i32, varint, OPTIONAL — the selected title-block credit, a `ScoreInfoFieldCode`; absent
///                         when no credit is selected.
/// ```
public enum SelectionTintCodec {
    public static func encode(argb: UInt32, ids: Set<ScoreItemID>) -> Data {
        encode(argb: argb, ids: ids, credit: nil)
    }

    /// `encode(argb:ids:)` with the selected title-block credit, which the draw program paints in `argb` too
    /// (`LayoutBridge.appendTitleFrame`). `nil` writes no tag 3, so the payload is `encode(argb:ids:)`'s byte for byte.
    package static func encode(argb: UInt32, ids: Set<ScoreItemID>, credit: ScoreInfoWrite.Field?) -> Data {
        SelectionTintWire(
            argb: argb,
            items: ids.map(ScoreItemIDWire.init(from:)),
            creditFieldCode: credit.map(ScoreInfoFieldCode.code(of:)),
        ).encodeToData()
    }

    public static func decode(_ data: Data) throws -> (argb: UInt32, ids: Set<ScoreItemID>) {
        let decoded = try decodeWithCredit(data)
        return (argb: decoded.argb, ids: decoded.ids)
    }

    /// `decode(_:)` with the selected credit: `nil` when tag 3 is absent (every payload written before it existed) or
    /// names no field this build knows (`ScoreInfoFieldCode.field(code:)`, which also answers `nil` for `-1`).
    package static func decodeWithCredit(
        _ data: Data,
    ) throws -> (argb: UInt32, ids: Set<ScoreItemID>, credit: ScoreInfoWrite.Field?) {
        let wire = try SelectionTintWire(decoding: data)
        return try (
            argb: wire.argb,
            ids: Set(wire.items.map { try $0.decoded() }),
            credit: wire.creditFieldCode.flatMap(ScoreInfoFieldCode.field(code:)),
        )
    }
}

/// Appended fields are Optional: Wirelet writes an Optional only when it holds a value and decodes its absence as
/// `nil`, so a payload without tag 3 stays byte-identical and still decodes (a defaulted non-Optional field would
/// be written every time and required on decode). The generated Kotlin `SelectionTint` takes it as
/// `creditFieldCode: Int? = null`, so every Kotlin call site written before it compiles unchanged.
@WireFormat
struct SelectionTintWire {
    var argb: UInt32
    var items: [ScoreItemIDWire]
    var creditFieldCode: Int32?
}

/// Codec for an *ordered* list of `ScoreItemID`s — what a marquee (rubber-band) query answers with.
///
/// A list rather than `SelectionTintWire`'s set, because `ScoreHitTester.itemIDs(in:)` states its
/// order as part of its contract: systems top-to-bottom, then `EventColumn.centerX` ascending
/// within a system. A host extending a selection with the keyboard, or naming "the first thing you
/// dragged over", needs that order, and a `Set` throws it away.
///
/// No color field either, for the same reason the two are separate calls: a marquee answers *what
/// is in the rect*, and how a host tints the result — if it tints it at all — is a later decision it
/// makes with `SelectionTintCodec`.
///
/// Wire layout (Wirelet's TLV scheme — see `EditIntentCodec.swift`'s doc comment for the
/// tag-and-varint format this describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: items  [ScoreItemIDWire] — length-delimited array, in query order.
/// ```
public enum ScoreItemIDListCodec {
    public static func encode(_ ids: [ScoreItemID]) -> Data {
        ScoreItemIDListWire(items: ids.map(ScoreItemIDWire.init(from:))).encodeToData()
    }

    public static func decode(_ data: Data) throws -> [ScoreItemID] {
        try ScoreItemIDListWire(decoding: data).items.map { try $0.decoded() }
    }
}

@WireFormat
struct ScoreItemIDListWire {
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
/// tag 1: xMm       f64, fixed64
/// tag 2: yMm       f64, fixed64
/// tag 3: widthMm   f64, fixed64
/// tag 4: heightMm  f64, fixed64
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

/// Codec for the bar a point falls in, which `nativeEditingMeasureHitTest` answers. The staff is full-score
/// addressed, like every editing answer that crosses the JNI boundary. `firstMeasureIndex ... lastMeasureIndex` is
/// the run a collapsed multi-measure rest stands for; the two are equal for an ordinary bar.
///
/// Wire layout (Wirelet's TLV scheme; see `EditIntentCodec.swift`'s doc comment for the tag-and-varint format this
/// describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: partIndex          i32, varint
/// tag 2: staffIndexInPart   i32, varint
/// tag 3: firstMeasureIndex  i32, varint
/// tag 4: lastMeasureIndex   i32, varint
/// ```
public enum EditMeasureHitCodec {
    public static func encode(staff: StaffAddress, measures: ClosedRange<Int>) -> Data {
        EditMeasureHitWire(
            partIndex: Int32(staff.partIndex),
            staffIndexInPart: Int32(staff.staffIndexInPart),
            firstMeasureIndex: Int32(measures.lowerBound),
            lastMeasureIndex: Int32(measures.upperBound),
        ).encodeToData()
    }

    public static func decode(_ data: Data) throws -> EditMeasureHitWire {
        try EditMeasureHitWire(decoding: data)
    }
}

@WireFormat
public struct EditMeasureHitWire: Equatable {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var firstMeasureIndex: Int32
    public var lastMeasureIndex: Int32
}
