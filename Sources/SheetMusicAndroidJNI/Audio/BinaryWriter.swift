import Foundation

/// Minimal little-endian byte sink for audio JNI codec blobs.
///
/// Mirrors the existing `BinaryWriter` in `DrawProgram.swift` but is
/// kept separate so the audio codecs can evolve their API independently
/// (e.g. `Int64`, `Bool`) without touching the draw-program format.
public struct AudioBinaryWriter {
    public private(set) var data = Data()

    public init() {}

    /// Append a fixed-width integer in little-endian byte order.
    public mutating func append<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Append a `Bool` as a single byte (0 = false, 1 = true).
    public mutating func append(_ value: Bool) {
        append(UInt8(value ? 1 : 0))
    }
}
