import SheetMusicFoundation

/// CRC-32 per RFC 1952 (the same variant used by ZIP and gzip).
/// Polynomial 0xEDB88320, initial register 0xFFFFFFFF, output XOR
/// 0xFFFFFFFF. Single Swift implementation used on every platform —
/// no platform branching, no zlib dependency for CRC.
enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// Compute CRC32 over the entire byte sequence.
    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
