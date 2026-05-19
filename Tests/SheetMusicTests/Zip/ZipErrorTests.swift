import Foundation
@testable import SheetMusicZip
import Testing

@Suite("ZipError paths")
struct ZipErrorTests {
    @Test
    func truncatedArchiveThrowsNotAZip() {
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(throws: ZipError.notAZip) {
            _ = try ZipReader(data: bytes)
        }
    }

    @Test
    func zip64MarkerRejected() throws {
        // Build a valid archive then patch its central-directory entry's
        // uncompressedSize field to 0xFFFFFFFF (ZIP64 marker).
        var writer = ZipWriter()
        try writer.add(path: "x", data: Data("hello".utf8), method: .deflate)
        var bytes = writer.finish()
        // Find the central directory header (PK\1\2) and patch its
        // uncompressed-size field.
        let pattern: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let idx = try #require(bytes.range(of: Data(pattern))).lowerBound
        // Layout: signature(4) + 20 + crc(4) + comp(4) + uncomp(4) ...
        let uncompOffset = idx + 4 + 20 + 4 + 4
        bytes.replaceSubrange(
            uncompOffset ..< uncompOffset + 4,
            with: Data([0xFF, 0xFF, 0xFF, 0xFF]),
        )
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: bytes)
        }
    }

    @Test
    func encryptionFlagRejected() throws {
        var writer = ZipWriter()
        try writer.add(path: "x", data: Data("hello".utf8), method: .deflate)
        var bytes = writer.finish()
        let pattern: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let idx = try #require(bytes.range(of: Data(pattern))).lowerBound
        // Layout: signature(4) + version-made-by(2) + version-needed(2)
        //         + gp-flags(2)
        let flagsOffset = idx + 4 + 2 + 2
        bytes[flagsOffset] |= 0x01
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: bytes)
        }
    }

    @Test
    func unknownMethodRejected() throws {
        var writer = ZipWriter()
        try writer.add(path: "x", data: Data("hello".utf8), method: .stored)
        var bytes = writer.finish()
        // Patch the central-directory method to 99 (AES marker).
        let pattern: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let idx = try #require(bytes.range(of: Data(pattern))).lowerBound
        let methodOffset = idx + 4 + 2 + 2 + 2
        bytes.replaceSubrange(
            methodOffset ..< methodOffset + 2,
            with: Data([0x63, 0x00]), // 99 LE
        )
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: bytes)
        }
    }
}
