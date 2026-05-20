import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Wire format for the playback cursor's bounding rect.
///
/// Bytes layout (34 bytes):
/// ```
///   u16 version (= 1)
///   i64 xMicros        // CGFloat * 1e6, rounded
///   i64 yMicros
///   i64 widthMicros
///   i64 heightMicros
/// ```
///
/// Empty byte array signals "no frame" (cursor didn't resolve).
public enum CursorFrameCodec {
    public static let formatVersion: UInt16 = 1

    /// Encode from pre-extracted Double components. Used on Android where
    /// `SheetMusicLayout.CGRect` and `Foundation.CGRect` are distinct types.
    public static func encodeComponents(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
    ) -> Data {
        var w = AudioBinaryWriter()
        w.append(formatVersion)
        w.append(Int64((x * 1_000_000).rounded()))
        w.append(Int64((y * 1_000_000).rounded()))
        w.append(Int64((width * 1_000_000).rounded()))
        w.append(Int64((height * 1_000_000).rounded()))
        return w.data
    }

    public static func encode(_ rect: CGRect) -> Data {
        encodeComponents(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height),
        )
    }

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

    public static func decode(_ data: Data) throws -> DecodedFrame? {
        if data.isEmpty { return nil }
        var r = AudioBinaryReader(data)
        try r.assertVersion(formatVersion)
        let x = try Double(r.readInt64()) / 1_000_000
        let y = try Double(r.readInt64()) / 1_000_000
        let w = try Double(r.readInt64()) / 1_000_000
        let h = try Double(r.readInt64()) / 1_000_000
        return DecodedFrame(x: x, y: y, width: w, height: h)
    }
}
