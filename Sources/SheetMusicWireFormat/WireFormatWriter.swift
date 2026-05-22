import Foundation

/// Minimal little-endian byte sink for wire-format encoding.
public struct WireFormatWriter {
    public private(set) var data = Data()

    public init() {}

    /// Append a fixed-width integer in little-endian byte order.
    public mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Append raw bytes (no endianness reinterpretation).
    public mutating func appendBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        data.append(contentsOf: bytes)
    }
}
