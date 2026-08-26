import SheetMusicFoundation

/// Little-endian cursor over a `Data` value. Used by ZipReader to walk
/// EOCD, central directory, and local file header records.
struct BinaryReader {
    private let data: Data
    private(set) var cursor: Int

    init(data: Data, cursor: Int = 0) {
        // Force `startIndex == 0`. `Data.subdata(in:)` (used by readBytes)
        // interprets its range as absolute indices into the underlying
        // buffer, not 0-based offsets, so a slice with non-zero
        // startIndex (as produced by `fullArchive[localHeaderOffset...]`
        // in ZipReader) would trap. Copying here is acceptable: ZIP
        // archives we read are at most a few MB.
        self.data = Data(data)
        self.cursor = cursor
    }

    var isAtEnd: Bool {
        cursor >= data.count
    }

    var remaining: Int {
        max(0, data.count - cursor)
    }

    mutating func seek(to offset: Int) throws {
        guard offset >= 0, offset <= data.count else {
            throw ZipError.corrupted("seek out of range: \(offset)")
        }
        cursor = offset
    }

    mutating func readUInt16LE() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return UInt16(bytes[bytes.startIndex])
            | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        let b = bytes.startIndex
        return UInt32(bytes[b])
            | (UInt32(bytes[b + 1]) << 8)
            | (UInt32(bytes[b + 2]) << 16)
            | (UInt32(bytes[b + 3]) << 24)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, cursor + count <= data.count else {
            throw ZipError.corrupted("read past end (count=\(count), remaining=\(remaining))")
        }
        let slice = data.subdata(in: cursor ..< cursor + count)
        cursor += count
        return slice
    }
}
