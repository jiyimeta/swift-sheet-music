import Foundation

/// Tiny mutable byte buffer with big-endian append helpers.
struct BinaryEncoder {
    var data = Data()

    mutating func appendUInt8(_ v: UInt8) {
        data.append(v)
    }

    mutating func appendUInt16BE(_ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}
