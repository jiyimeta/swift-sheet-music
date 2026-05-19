import Foundation

/// Appends little-endian primitives to a `Data` buffer. Used by ZipWriter.
struct BinaryWriter {
    private(set) var data = Data()

    var offset: Int {
        data.count
    }

    mutating func writeUInt16LE(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func writeUInt32LE(_ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }
}
