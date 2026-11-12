import SheetMusicFoundation
import Wirelet

/// Codec for where an engraved title-block credit sits, which `nativeCreditTextHit` and `nativeCreditTextFrame`
/// answer: which credit it is, and the box of its line in document millimetres (Y down). Millimetres throughout, like
/// `SelectionInkFramesCodec`, because the only writer is the JNI boundary, which has already converted.
///
/// Here rather than in `SheetMusicBridgeCore` so a Kotlin host can read it: this directory is the one
/// `:SheetMusicAudioAndroid`'s `editGeometry` wirelet source set scans with `emitModels`, so the generated
/// `CreditTextFrameCodec` and `CreditTextFrame` come with the AAR.
///
/// Wire layout (Wirelet's TLV scheme — see `EditIntentCodec.swift`'s doc comment for the tag-and-varint format this
/// describes):
/// ```
/// varint(payloadLength) + payload, where payload is:
/// tag 1: fieldCode  i32 — `ScoreInfoFieldCode`: 0 title / 1 subtitle / 2 composer / 3 arranger /
///                   4 lyricist / 5 copyright.
/// tag 2: xMm        f64, fixed64
/// tag 3: yMm        f64, fixed64
/// tag 4: widthMm    f64, fixed64
/// tag 5: heightMm   f64, fixed64
/// tag 6: spMm       f64, fixed64 — `StaffMetrics.sp`, one staff space, for a host sizing a control off the line
///                   (as `SelectionInkFramesCodec.spMm` does).
/// ```
public enum CreditTextFrameCodec {
    public static func encode(
        fieldCode: Int32, xMm: Double, yMm: Double, widthMm: Double, heightMm: Double, spMm: Double,
    ) -> Data {
        CreditTextFrameWire(
            fieldCode: fieldCode, xMm: xMm, yMm: yMm, widthMm: widthMm, heightMm: heightMm, spMm: spMm,
        ).encodeToData()
    }

    public static func decode(_ data: Data) throws -> CreditTextFrameWire {
        try CreditTextFrameWire(decoding: data)
    }
}

@WireFormat
public struct CreditTextFrameWire: Equatable {
    public var fieldCode: Int32
    public var xMm: Double
    public var yMm: Double
    public var widthMm: Double
    public var heightMm: Double
    public var spMm: Double

    public init(fieldCode: Int32, xMm: Double, yMm: Double, widthMm: Double, heightMm: Double, spMm: Double) {
        self.spMm = spMm
        self.fieldCode = fieldCode
        self.xMm = xMm
        self.yMm = yMm
        self.widthMm = widthMm
        self.heightMm = heightMm
    }
}
