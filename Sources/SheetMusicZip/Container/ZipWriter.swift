import Foundation

/// Builds a ZIP archive in memory. Scope mirrors ZipReader's accepted
/// feature set: STORED or DEFLATE entries, UTF-8 names (gp bit 11 set),
/// no data descriptor, no ZIP64.
public struct ZipWriter {
    private var buffer = BinaryWriter()
    private var records: [Record] = []

    /// Used internally to remember enough state to emit the central
    /// directory entry in `finish()`.
    private struct Record {
        let path: String
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: ZipCompressionMethod
        let localHeaderOffset: UInt32
    }

    public init() {}

    public mutating func add(
        path: String,
        data: Data,
        method: ZipCompressionMethod = .deflate,
    ) throws {
        guard !path.isEmpty else {
            throw ZipError.corrupted("empty entry path")
        }
        guard data.count <= UInt32.max else {
            throw ZipError.unsupportedFeature("entry > 4 GiB (ZIP64 needed)")
        }
        let nameBytes = Data(path.utf8)
        let localOffset = UInt32(buffer.offset)
        let crc = CRC32.compute(data)
        let payload: Data
        switch method {
        case .stored:
            payload = data
        case .deflate:
            payload = try Deflate.compress(data)
        }
        guard payload.count <= UInt32.max else {
            throw ZipError.unsupportedFeature("compressed entry > 4 GiB (ZIP64 needed)")
        }

        // local file header
        buffer.writeUInt32LE(0x0403_4B50)
        buffer.writeUInt16LE(20) // version needed
        buffer.writeUInt16LE(0x0800) // gp flags: bit 11 (UTF-8)
        buffer.writeUInt16LE(method.rawValue)
        buffer.writeUInt32LE(0) // mtime/mdate = 0
        buffer.writeUInt32LE(crc)
        buffer.writeUInt32LE(UInt32(payload.count))
        buffer.writeUInt32LE(UInt32(data.count))
        buffer.writeUInt16LE(UInt16(nameBytes.count))
        buffer.writeUInt16LE(0) // extra length
        buffer.writeBytes(nameBytes)
        buffer.writeBytes(payload)

        records.append(Record(
            path: path,
            crc32: crc,
            compressedSize: UInt32(payload.count),
            uncompressedSize: UInt32(data.count),
            method: method,
            localHeaderOffset: localOffset,
        ))
    }

    public consuming func finish() -> Data {
        let centralDirOffset = UInt32(buffer.offset)
        for r in records {
            let nameBytes = Data(r.path.utf8)
            buffer.writeUInt32LE(0x0201_4B50) // central signature
            buffer.writeUInt16LE(20) // version made by
            buffer.writeUInt16LE(20) // version needed
            buffer.writeUInt16LE(0x0800) // gp flags
            buffer.writeUInt16LE(r.method.rawValue)
            buffer.writeUInt32LE(0) // mtime/mdate
            buffer.writeUInt32LE(r.crc32)
            buffer.writeUInt32LE(r.compressedSize)
            buffer.writeUInt32LE(r.uncompressedSize)
            buffer.writeUInt16LE(UInt16(nameBytes.count))
            buffer.writeUInt16LE(0) // extra length
            buffer.writeUInt16LE(0) // comment length
            buffer.writeUInt16LE(0) // disk number start
            buffer.writeUInt16LE(0) // internal attrs
            buffer.writeUInt32LE(0) // external attrs
            buffer.writeUInt32LE(r.localHeaderOffset)
            buffer.writeBytes(nameBytes)
        }
        let centralDirSize = UInt32(buffer.offset) - centralDirOffset

        // EOCD
        buffer.writeUInt32LE(0x0605_4B50)
        buffer.writeUInt16LE(0) // this disk
        buffer.writeUInt16LE(0) // disk with cd
        buffer.writeUInt16LE(UInt16(records.count)) // entries this disk
        buffer.writeUInt16LE(UInt16(records.count)) // entries total
        buffer.writeUInt32LE(centralDirSize)
        buffer.writeUInt32LE(centralDirOffset)
        buffer.writeUInt16LE(0) // comment length
        return buffer.data
    }
}
