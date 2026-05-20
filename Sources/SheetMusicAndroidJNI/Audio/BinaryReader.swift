import Foundation

/// Pull-style little-endian byte reader for audio JNI codec blobs.
///
/// Unlike the `BinaryReader` in `DrawProgram.swift` (which uses `precondition`),
/// this version throws `BinaryReaderError` on unexpected EOF or version mismatch,
/// allowing callers to propagate decode failures as typed errors rather than
/// crashing.
public struct AudioBinaryReader {
    public enum BinaryReaderError: Error, Equatable {
        /// The buffer was exhausted before the requested bytes could be read.
        case underflow
        /// The blob's version field did not match the expected version.
        case versionMismatch(expected: UInt16, found: UInt16)
    }

    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = 0
    }

    // MARK: - Primitive reads

    public mutating func readUInt8() throws -> UInt8 {
        try requireBytes(1)
        let v = data[data.startIndex + offset]
        offset += 1
        return v
    }

    public mutating func readUInt16() throws -> UInt16 {
        try requireBytes(2)
        var v: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(
                to: dest,
                from: (data.startIndex + offset) ..< (data.startIndex + offset + 2),
            )
        }
        offset += 2
        return UInt16(littleEndian: v)
    }

    public mutating func readInt32() throws -> Int32 {
        try requireBytes(4)
        var v: Int32 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(
                to: dest,
                from: (data.startIndex + offset) ..< (data.startIndex + offset + 4),
            )
        }
        offset += 4
        return Int32(littleEndian: v)
    }

    public mutating func readInt64() throws -> Int64 {
        try requireBytes(8)
        var v: Int64 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(
                to: dest,
                from: (data.startIndex + offset) ..< (data.startIndex + offset + 8),
            )
        }
        offset += 8
        return Int64(littleEndian: v)
    }

    public mutating func readBool() throws -> Bool {
        let byte = try readUInt8()
        return byte != 0
    }

    /// Read `count` raw bytes (no endianness reinterpretation).
    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try requireBytes(count)
        let start = data.startIndex + offset
        let slice = data[start ..< start + count]
        offset += count
        return Array(slice)
    }

    // MARK: - Version assertion

    /// Read a `u16` version field and throw `.versionMismatch` if it
    /// does not equal `expected`.
    public mutating func assertVersion(_ expected: UInt16) throws {
        let found = try readUInt16()
        guard found == expected else {
            throw BinaryReaderError.versionMismatch(expected: expected, found: found)
        }
    }

    // MARK: - Private helpers

    private func requireBytes(_ count: Int) throws {
        guard offset + count <= data.count else {
            throw BinaryReaderError.underflow
        }
    }
}
