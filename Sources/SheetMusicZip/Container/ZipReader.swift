import Foundation

/// Reads ZIP archives produced by SheetMusicZip, MuseScore Studio, and
/// other standard ZIP writers. Scope: STORED + DEFLATE, single-disk,
/// ≤ 65534 entries, no encryption, no ZIP64. See the spec for the full
/// supported-feature matrix.
struct ZipReader {
    let entries: [String: ZipEntry]
    private let data: Data

    init(data: Data) throws {
        // Normalize to a `startIndex == 0` buffer so direct integer
        // subscripts in `findEOCD` and absolute-offset reads in
        // BinaryReader behave consistently regardless of whether the
        // caller passes a slice.
        let normalized = Data(data)
        self.data = normalized
        entries = try Self.parseCentralDirectory(normalized)
    }

    func contains(path: String) -> Bool {
        entries[path] != nil
    }

    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50

    /// Walk from the tail (up to 65557 bytes back — 22-byte EOCD plus
    /// max 65535-byte trailing comment) looking for the EOCD signature.
    private static func findEOCD(in data: Data) throws -> Int {
        let minHead = 22
        guard data.count >= minHead else {
            throw ZipError.notAZip
        }
        let lowerBound = max(0, data.count - minHead - 0xFFFF)
        var pos = data.count - minHead
        while pos >= lowerBound {
            if data[pos] == 0x50, data[pos + 1] == 0x4B,
               data[pos + 2] == 0x05, data[pos + 3] == 0x06
            {
                return pos
            }
            pos -= 1
        }
        throw ZipError.notAZip
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [String: ZipEntry] {
        let eocdOffset = try findEOCD(in: data)
        var reader = BinaryReader(data: data, cursor: eocdOffset)
        let signature = try reader.readUInt32LE()
        guard signature == eocdSignature else {
            throw ZipError.corrupted("EOCD signature mismatch")
        }
        let thisDisk = try reader.readUInt16LE()
        let diskWithCD = try reader.readUInt16LE()
        let entriesThisDisk = try reader.readUInt16LE()
        let entriesTotal = try reader.readUInt16LE()
        let cdSize = try reader.readUInt32LE()
        let cdOffset = try reader.readUInt32LE()
        guard thisDisk == 0, diskWithCD == 0 else {
            throw ZipError.unsupportedFeature("multi-disk archives")
        }
        guard cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF,
              entriesTotal != 0xFFFF
        else {
            throw ZipError.unsupportedFeature("ZIP64")
        }
        guard entriesThisDisk == entriesTotal else {
            throw ZipError.corrupted("disk entry count disagreement")
        }

        try reader.seek(to: Int(cdOffset))
        var out: [String: ZipEntry] = [:]
        out.reserveCapacity(Int(entriesTotal))
        for _ in 0 ..< entriesTotal {
            let entry = try parseCentralEntry(&reader, in: data)
            out[entry.path] = entry
        }
        return out
    }

    private static func parseCentralEntry(
        _ reader: inout BinaryReader, in data: Data,
    ) throws -> ZipEntry {
        let sig = try reader.readUInt32LE()
        guard sig == centralSignature else {
            throw ZipError.corrupted("central directory signature mismatch")
        }
        _ = try reader.readUInt16LE() // version made by
        _ = try reader.readUInt16LE() // version needed
        let gpFlags = try reader.readUInt16LE()
        let methodRaw = try reader.readUInt16LE()
        _ = try reader.readUInt32LE() // mtime/mdate
        let crc = try reader.readUInt32LE()
        let compSize = try reader.readUInt32LE()
        let uncompSize = try reader.readUInt32LE()
        let nameLen = try reader.readUInt16LE()
        let extraLen = try reader.readUInt16LE()
        let commentLen = try reader.readUInt16LE()
        _ = try reader.readUInt16LE() // disk number start
        _ = try reader.readUInt16LE() // internal attrs
        _ = try reader.readUInt32LE() // external attrs
        let localHeaderOffset = try reader.readUInt32LE()
        let nameBytes = try reader.readBytes(count: Int(nameLen))
        _ = try reader.readBytes(count: Int(extraLen))
        _ = try reader.readBytes(count: Int(commentLen))

        // Reject unsupported features.
        if (gpFlags & 0x0001) != 0 {
            throw ZipError.unsupportedFeature("encrypted entry")
        }
        if (gpFlags & 0x0008) != 0 {
            throw ZipError.unsupportedFeature("data descriptor (bit 3)")
        }
        if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF
            || localHeaderOffset == 0xFFFF_FFFF
        {
            throw ZipError.unsupportedFeature("ZIP64")
        }
        guard let method = ZipCompressionMethod(rawValue: methodRaw) else {
            throw ZipError.unsupportedFeature("compression method \(methodRaw)")
        }
        guard let path = String(data: nameBytes, encoding: .utf8) else {
            throw ZipError.corrupted("non-UTF8 entry name")
        }

        // Resolve payload range by reading the local file header just
        // for its variable-length fields.
        let payloadRange = try locatePayload(
            in: data, localHeaderOffset: Int(localHeaderOffset),
            compressedSize: Int(compSize),
        )

        return ZipEntry(
            path: path,
            uncompressedSize: uncompSize,
            compressedSize: compSize,
            crc32: crc,
            method: method,
            payloadRange: payloadRange,
        )
    }

    private static func locatePayload(
        in data: Data, localHeaderOffset offset: Int, compressedSize: Int,
    ) throws -> Range<Int> {
        var r = BinaryReader(data: data, cursor: offset)
        let sig = try r.readUInt32LE()
        guard sig == localSignature else {
            throw ZipError.corrupted("local file header signature mismatch")
        }
        _ = try r.readUInt16LE() // version needed
        _ = try r.readUInt16LE() // gp flags
        _ = try r.readUInt16LE() // method
        _ = try r.readUInt32LE() // mtime/mdate
        _ = try r.readUInt32LE() // crc
        _ = try r.readUInt32LE() // comp size
        _ = try r.readUInt32LE() // uncomp size
        let nameLen = try r.readUInt16LE()
        let extraLen = try r.readUInt16LE()
        _ = try r.readBytes(count: Int(nameLen))
        _ = try r.readBytes(count: Int(extraLen))
        let start = r.cursor
        let end = start + compressedSize
        guard end <= data.count else {
            throw ZipError.corrupted("payload extends past archive end")
        }
        return start ..< end
    }
}
