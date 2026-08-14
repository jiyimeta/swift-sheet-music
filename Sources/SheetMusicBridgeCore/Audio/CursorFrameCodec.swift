import SheetMusicFoundation
import Wirelet
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Wire format for the playback cursor's bounding rect.
///
/// The bytes are the wirelet `@WireFormat` encoding of `DecodedFrame`
/// (length-prefixed, with a tag per field), NOT a raw 4×f64 blob — decode on
/// the Kotlin side with the generated `DecodedFrameCodec`, not by reading raw
/// doubles. Empty byte array signals "no frame" (cursor didn't resolve).
public enum CursorFrameCodec {
    @WireFormat
    public struct DecodedFrame: Equatable {
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

    /// Encode from pre-extracted Double components. Used on Android where
    /// `SheetMusicLayout.CGRect` and `Foundation.CGRect` are distinct types.
    public static func encodeComponents(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
    ) -> Data {
        DecodedFrame(x: x, y: y, width: width, height: height).encodeToData()
    }

    // Apple-only, and not for want of trying: `CGRect` reaches this file from CoreGraphics and from
    // nowhere else once the target is off the Foundation umbrella. Android used to borrow
    // swift-corelibs-foundation's own `CGRect`, and `FoundationEssentials` carries no such type on
    // either Android or WASI. Callers there use `encodeComponents` above, which is what the JNI
    // bridge already does — this overload has no caller in Sources at all, only Apple tests.
    #if canImport(CoreGraphics)
        public static func encode(_ rect: CGRect) -> Data {
            encodeComponents(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.size.width),
                height: Double(rect.size.height),
            )
        }
    #endif

    public static func decode(_ data: Data) throws -> DecodedFrame? {
        if data.isEmpty { return nil }
        return try DecodedFrame(decoding: data)
    }
}
