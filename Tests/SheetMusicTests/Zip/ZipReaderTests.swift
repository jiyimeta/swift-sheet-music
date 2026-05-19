import Foundation
@testable import SheetMusicZip
import Testing

@Suite("ZipReader")
struct ZipReaderTests {
    /// A pre-computed minimal valid ZIP archive containing one STORED
    /// entry "hi.txt" with payload "hello\n". Hand-built so we don't
    /// depend on ZipWriter for ZipReader's first test.
    private static let minimalStoredArchive: Data = buildMinimalStoredArchive()

    private static func buildMinimalStoredArchive() -> Data {
        var d = Data()
        appendLocalHeader(into: &d)
        let centralDirOffset = UInt32(d.count)
        appendCentralEntry(into: &d, localHeaderOffset: 0)
        let centralDirSize = UInt32(d.count) - centralDirOffset
        appendEOCD(into: &d, cdSize: centralDirSize, cdOffset: centralDirOffset)
        return d
    }

    private static func appendLocalHeader(into d: inout Data) {
        // local file header (30 + 6 name + 6 payload)
        d.append(Data([0x50, 0x4B, 0x03, 0x04])) // PK\3\4
        d.append(Data([0x14, 0x00])) // version needed = 20
        d.append(Data([0x00, 0x08])) // gp flags: bit 11 (UTF-8)
        d.append(Data([0x00, 0x00])) // method = stored
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // mtime/mdate
        // crc32 of "hello\n" = 0x363A3020
        d.append(Data([0x20, 0x30, 0x3A, 0x36]))
        d.append(Data([0x06, 0x00, 0x00, 0x00])) // compressed size = 6
        d.append(Data([0x06, 0x00, 0x00, 0x00])) // uncompressed size = 6
        d.append(Data([0x06, 0x00])) // file name length = 6
        d.append(Data([0x00, 0x00])) // extra length = 0
        d.append(Data("hi.txt".utf8))
        d.append(Data("hello\n".utf8))
    }

    private static func appendCentralEntry(into d: inout Data, localHeaderOffset: UInt32) {
        d.append(Data([0x50, 0x4B, 0x01, 0x02])) // PK\1\2
        d.append(Data([0x14, 0x00])) // version made by
        d.append(Data([0x14, 0x00])) // version needed
        d.append(Data([0x00, 0x08])) // gp flags
        d.append(Data([0x00, 0x00])) // method
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // mtime/mdate
        d.append(Data([0x20, 0x30, 0x3A, 0x36])) // crc32
        d.append(Data([0x06, 0x00, 0x00, 0x00])) // comp size
        d.append(Data([0x06, 0x00, 0x00, 0x00])) // uncomp size
        d.append(Data([0x06, 0x00])) // name length
        d.append(Data([0x00, 0x00])) // extra length
        d.append(Data([0x00, 0x00])) // comment length
        d.append(Data([0x00, 0x00])) // disk number start
        d.append(Data([0x00, 0x00])) // internal attrs
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // external attrs
        d.append(withUnsafeBytes(of: localHeaderOffset.littleEndian) { Data($0) })
        d.append(Data("hi.txt".utf8))
    }

    private static func appendEOCD(into d: inout Data, cdSize: UInt32, cdOffset: UInt32) {
        d.append(Data([0x50, 0x4B, 0x05, 0x06]))
        d.append(Data([0x00, 0x00])) // this disk
        d.append(Data([0x00, 0x00])) // disk with central dir
        d.append(Data([0x01, 0x00])) // # entries this disk
        d.append(Data([0x01, 0x00])) // # entries total
        d.append(withUnsafeBytes(of: cdSize.littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: cdOffset.littleEndian) { Data($0) })
        d.append(Data([0x00, 0x00])) // comment length
    }

    @Test
    func opensMinimalStoredArchive() throws {
        let reader = try ZipReader(data: Self.minimalStoredArchive)
        #expect(reader.entries.count == 1)
        let entry = try #require(reader.entries["hi.txt"])
        #expect(entry.method == .stored)
        #expect(entry.uncompressedSize == 6)
        #expect(entry.compressedSize == 6)
        #expect(entry.crc32 == 0x363A_3020)
    }

    @Test
    func eocdAtTrueTail() throws {
        // Append a junk comment to push EOCD away from the tail.
        var bytes = Self.minimalStoredArchive
        // Bump the EOCD comment length and append the comment bytes.
        let eocdStart = bytes.count - 22
        let commentLengthOffset = eocdStart + 20
        let comment = Data("trailing junk".utf8)
        let commentLen = UInt16(comment.count).littleEndian
        bytes.replaceSubrange(
            commentLengthOffset ..< commentLengthOffset + 2,
            with: withUnsafeBytes(of: commentLen) { Data($0) },
        )
        bytes.append(comment)
        let reader = try ZipReader(data: bytes)
        #expect(reader.entries["hi.txt"] != nil)
    }

    @Test
    func notAZipThrows() {
        #expect(throws: ZipError.self) {
            _ = try ZipReader(data: Data("not a zip".utf8))
        }
    }
}
