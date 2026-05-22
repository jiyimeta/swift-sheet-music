import Foundation

/// Forward-only little-endian byte cursor for wire-format decoding.
///
/// The reader is value-type — `try Foo(from: &reader)` advances the
/// cursor in-place. Pass `inout` consistently to keep that semantic.
public struct WireFormatReader {
    public let data: Data
    public private(set) var offset = 0

    public init(data: Data) {
        self.data = data
    }

    public var remaining: Int {
        data.count - offset
    }

    public var isAtEnd: Bool {
        offset >= data.count
    }

    /// Read a fixed-width integer in little-endian byte order.
    public mutating func readInteger<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else {
            throw WireFormatError.truncated(needed: size, remaining: remaining)
        }
        let value: T = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return T(littleEndian: value)
    }

    /// Read `count` raw bytes and advance the cursor.
    public mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw WireFormatError.invalidCount(Int32(clamping: count))
        }
        guard remaining >= count else {
            throw WireFormatError.truncated(needed: count, remaining: remaining)
        }
        let start = data.startIndex + offset
        let slice = data[start ..< (start + count)]
        offset += count
        return Data(slice)
    }
}
