import SheetMusicFoundation
import Wirelet

/// Codec for where a selected clef or engraved element is drawn, which `nativeSelectionInkFrames` answers: one
/// rectangle per place the selection is drawn, in document millimetres, and the staff space it was engraved at.
/// Millimetres throughout, like `RangeBoxFramesCodec`, because the only writer is the JNI boundary, which has already
/// converted.
///
/// Here rather than in `SheetMusicBridgeCore` so a Kotlin host can read it: this directory is the one
/// `:SheetMusicAudioAndroid`'s `editGeometry` wirelet source set scans with `emitModels`, so the generated
/// `SelectionInkFramesCodec` and its `SelectionInkFrames` / `SelectionInkFrame` models come with the AAR, beside the
/// `ScoreItemID` payload the verb takes.
///
/// Wire layout (Wirelet's TLV scheme — see `EditIntentCodec.swift`'s doc comment for the tag-and-varint format this
/// describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: spMm    f64, fixed64 — `StaffMetrics.sp`, one staff space, for a host spacing a control off the glyph.
/// tag 2: frames  [SelectionInkFrameWire] — length-delimited array, one per place drawn, in document order.
///
/// SelectionInkFrameWire:
/// tag 1: xMm       f64, fixed64
/// tag 2: yMm       f64, fixed64
/// tag 3: widthMm   f64, fixed64
/// tag 4: heightMm  f64, fixed64
/// ```
public enum SelectionInkFramesCodec {
    public static func encode(spMm: Double, frames: [SelectionInkFrameWire]) -> Data {
        SelectionInkFramesWire(spMm: spMm, frames: frames).encodeToData()
    }

    public static func decode(_ data: Data) throws -> SelectionInkFramesWire {
        try SelectionInkFramesWire(decoding: data)
    }
}

@WireFormat
public struct SelectionInkFramesWire: Equatable {
    public var spMm: Double
    public var frames: [SelectionInkFrameWire]
}

/// One place a selected clef or element is drawn, in document millimetres (Y down): the box
/// `ScoreHitTester.clefHitRects(for:)` / `elementHitRects(for:)` measure for it.
@WireFormat
public struct SelectionInkFrameWire: Equatable {
    public var xMm: Double
    public var yMm: Double
    public var widthMm: Double
    public var heightMm: Double

    public init(xMm: Double, yMm: Double, widthMm: Double, heightMm: Double) {
        self.xMm = xMm
        self.yMm = yMm
        self.widthMm = widthMm
        self.heightMm = heightMm
    }
}
