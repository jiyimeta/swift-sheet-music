import SheetMusicFoundation
import SheetMusicZip

/// A `/FlateDecode` stream's bytes: the zlib format (RFC 1950) — a two-byte header, raw DEFLATE from
/// `SheetMusicZip`'s backend (Apple's Compression or zlib), and the Adler-32 of the input, big-endian.
enum FlateStream {
    static func encode(_ data: Data) throws -> Data {
        // CMF 0x78: deflate with a 32 KiB window; FLG 0x9C: the default level, and (0x789C % 31 == 0) the check bits.
        var encoded = Data([0x78, 0x9C])
        // An empty input deflates to nothing in the backend; a zlib stream still needs one final, empty block.
        encoded += data.isEmpty ? Data([0x03, 0x00]) : try Deflate.compress(data)
        let checksum = adler32(data)
        encoded += Data([
            UInt8(checksum >> 24 & 0xFF), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 8 & 0xFF),
            UInt8(checksum & 0xFF),
        ])
        return encoded
    }

    /// Decode a PDF zlib stream, tolerating a wrong Adler-32 as PDF readers do. Throws past `limit` decoded bytes.
    static func decode(_ data: Data, limit: Int) throws -> Data {
        guard data.count >= 2 else { throw PDFAppendError.unreadable }
        return try Deflate.inflate(Data(data.dropFirst(2)), limit: limit)
    }

    /// RFC 1950's checksum.
    static func adler32(_ data: Data) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in data {
            low = (low + UInt32(byte)) % 65521
            high = (high + low) % 65521
        }
        return high << 16 | low
    }
}
