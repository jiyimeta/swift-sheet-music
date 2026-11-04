import SheetMusicFoundation
import Wirelet

/// Codec for the outline a range selection draws, which `nativeRangeBoxFrames` answers: one rectangle per system the
/// selection reaches, in document millimetres, and the stroke they are all drawn at. Millimetres throughout, like
/// `EditCaretFrameCodec`, because the only writer is the JNI boundary, which has already converted.
///
/// Here rather than beside `StaffBandWire` in `SheetMusicBridgeCore` so a Kotlin host can read it: this directory is
/// the one `:SheetMusicAudioAndroid`'s `editGeometry` wirelet source set scans with `emitModels`, so the generated
/// `RangeBoxFramesCodec` and its `RangeBoxFrames` / `RangeBoxFrame` models come with the AAR, beside the
/// `SelectionTint` payload the verb takes.
///
/// Wire layout (Wirelet's TLV scheme — see `EditIntentCodec.swift`'s doc comment for the tag-and-varint format this
/// describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: lineWidthMm  f64, fixed64 — `StaffMetrics.rangeBoxLineWidth`, the same for every frame.
/// tag 2: frames       [RangeBoxFrameWire] — length-delimited array, in `LayoutDocument.systems` order.
///
/// RangeBoxFrameWire:
/// tag 1: xMm       f64, fixed64
/// tag 2: yMm       f64, fixed64
/// tag 3: widthMm   f64, fixed64
/// tag 4: heightMm  f64, fixed64
/// ```
public enum RangeBoxFramesCodec {
    public static func encode(lineWidthMm: Double, frames: [RangeBoxFrameWire]) -> Data {
        RangeBoxFramesWire(lineWidthMm: lineWidthMm, frames: frames).encodeToData()
    }

    public static func decode(_ data: Data) throws -> RangeBoxFramesWire {
        try RangeBoxFramesWire(decoding: data)
    }
}

@WireFormat
public struct RangeBoxFramesWire: Equatable {
    public var lineWidthMm: Double
    public var frames: [RangeBoxFrameWire]
}

/// One system's range box in document millimetres (Y down): the rectangle the stroke is centered on, as
/// `ScoreLayerBuilder.drawRangeBoxes` strokes it.
@WireFormat
public struct RangeBoxFrameWire: Equatable {
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
