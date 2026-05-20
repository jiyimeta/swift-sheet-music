import Foundation

/// Self-describing binary format that ferries layout output across the JNI
/// boundary. Little-endian throughout. Both the Swift encoder and the Kotlin
/// decoder must agree on the magic + version; mismatches are fail-fast.
public enum DrawProgram {
    public static let magic: UInt32 = 0x534D_4450 // "SMDP"
    /// v3 adds the `cubicTo` opcode (0x08). v2 added `setColor` (0x07).
    /// Older decoders must reject newer payloads.
    public static let version: UInt32 = 3

    public enum Opcode: UInt8 {
        case moveTo = 0x01
        case lineTo = 0x02
        case stroke = 0x03
        case fillRect = 0x04
        case glyph = 0x05
        case text = 0x06
        /// Sets the active paint colour (ARGB, 0xAARRGGBB). All draw
        /// commands until the next `setColor` use this colour; the
        /// initial colour is opaque black (0xFF000000).
        case setColor = 0x07
        /// Cubic Bezier curve from the current point to (x, y) with
        /// control points (cx1, cy1) and (cx2, cy2). Used for tie /
        /// slur arcs so Compose can render a true cubic with native
        /// anti-aliasing instead of a many-segment polyline.
        case cubicTo = 0x08
    }

    public enum FontID: UInt8, Sendable {
        case textRoman = 0x00 // body text (Edwin / system serif)
        case smufl = 0x01 // music glyphs (Bravura / Edwin SMuFL)
    }
}

/// Minimal LE byte sink. No throws on append; capacity grows naturally.
public struct BinaryWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func append<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    public mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    public mutating func append(utf8 string: String) {
        let bytes = Array(string.utf8)
        precondition(
            bytes.count <= Int(UInt16.max),
            "draw-program text payload exceeds 65535 bytes",
        )
        append(UInt16(bytes.count))
        data.append(contentsOf: bytes)
    }
}

/// Pull-style LE byte reader. Used only by Swift-side tests (the production
/// decoder is the Kotlin DrawProgramDecoder).
public struct BinaryReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
        let size = MemoryLayout<T>.size
        precondition(offset + size <= data.count, "draw-program read overflow")
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset ..< (offset + size))
        }
        offset += size
        return T(littleEndian: value)
    }

    public mutating func readDouble() -> Double {
        Double(bitPattern: read(UInt64.self))
    }

    public mutating func readUTF8() -> String {
        let len = Int(read(UInt16.self))
        precondition(offset + len <= data.count, "draw-program string overflow")
        let bytes = data.subdata(in: offset ..< (offset + len))
        offset += len
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
