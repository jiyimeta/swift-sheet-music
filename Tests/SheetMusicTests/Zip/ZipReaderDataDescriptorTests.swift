import Foundation
@testable import SheetMusicZip
import Testing

/// Streaming ZIP writers (MuseScore's Qt-based `MQZipWriter` among
/// them) set general-purpose flag bit 3 and park the CRC and sizes in
/// a data descriptor *after* the payload, leaving the local file
/// header's copies zeroed. The central directory written at the end
/// always carries the real values, and `ZipReader` reads exclusively
/// from there, so such archives are ordinary reads.
@Suite("ZipReader data descriptor")
struct ZipReaderDataDescriptorTests {
    private static let payload = Data("hello\n".utf8)
    private static let name = "hi.txt"
    private static let crc: UInt32 = 0x363A_3020 // crc32("hello\n")

    /// `withSignature: false` exercises the older 12-byte descriptor —
    /// APPNOTE 4.3.9.3 makes the `PK\7\8` signature optional, and the
    /// reader must not depend on either shape.
    private static func archive(withSignature: Bool) -> Data {
        var d = Data()
        appendLocalHeader(into: &d)
        d.append(payload)
        appendDataDescriptor(into: &d, withSignature: withSignature)
        let cdOffset = UInt32(d.count)
        appendCentralEntry(into: &d)
        let cdSize = UInt32(d.count) - cdOffset
        appendEOCD(into: &d, cdSize: cdSize, cdOffset: cdOffset)
        return d
    }

    private static func appendLocalHeader(into d: inout Data) {
        d.append(Data([0x50, 0x4B, 0x03, 0x04])) // PK\3\4
        d.append(Data([0x14, 0x00])) // version needed = 20
        d.append(Data([0x08, 0x08])) // gp flags: bit 3 (data descriptor) + bit 11
        d.append(Data([0x00, 0x00])) // method = stored
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // mtime/mdate
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // crc32 = 0 (deferred)
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // compressed size = 0 (deferred)
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // uncompressed size = 0 (deferred)
        d.append(le16(UInt16(name.utf8.count))) // file name length
        d.append(Data([0x00, 0x00])) // extra length
        d.append(Data(name.utf8))
    }

    private static func appendDataDescriptor(into d: inout Data, withSignature: Bool) {
        if withSignature {
            d.append(Data([0x50, 0x4B, 0x07, 0x08])) // PK\7\8
        }
        d.append(le32(crc))
        d.append(le32(UInt32(payload.count))) // compressed size
        d.append(le32(UInt32(payload.count))) // uncompressed size
    }

    private static func appendCentralEntry(into d: inout Data) {
        d.append(Data([0x50, 0x4B, 0x01, 0x02])) // PK\1\2
        d.append(Data([0x14, 0x00])) // version made by
        d.append(Data([0x14, 0x00])) // version needed
        d.append(Data([0x08, 0x08])) // gp flags: bit 3 + bit 11
        d.append(Data([0x00, 0x00])) // method = stored
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // mtime/mdate
        d.append(le32(crc)) // the authoritative crc
        d.append(le32(UInt32(payload.count))) // the authoritative comp size
        d.append(le32(UInt32(payload.count))) // the authoritative uncomp size
        d.append(le16(UInt16(name.utf8.count))) // name length
        d.append(Data([0x00, 0x00])) // extra length
        d.append(Data([0x00, 0x00])) // comment length
        d.append(Data([0x00, 0x00])) // disk number start
        d.append(Data([0x00, 0x00])) // internal attrs
        d.append(Data([0x00, 0x00, 0x00, 0x00])) // external attrs
        d.append(le32(0)) // local header offset
        d.append(Data(name.utf8))
    }

    private static func appendEOCD(into d: inout Data, cdSize: UInt32, cdOffset: UInt32) {
        d.append(Data([0x50, 0x4B, 0x05, 0x06]))
        d.append(Data([0x00, 0x00])) // this disk
        d.append(Data([0x00, 0x00])) // disk with central dir
        d.append(Data([0x01, 0x00])) // # entries this disk
        d.append(Data([0x01, 0x00])) // # entries total
        d.append(le32(cdSize))
        d.append(le32(cdOffset))
        d.append(Data([0x00, 0x00])) // comment length
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    @Test("bit-3 entry reads its payload from the central-directory sizes")
    func readsDataDescriptorEntry() throws {
        let reader = try ZipReader(data: Self.archive(withSignature: true))
        let entry = try #require(reader.entries[Self.name])
        #expect(entry.crc32 == Self.crc)
        #expect(entry.uncompressedSize == UInt32(Self.payload.count))
        #expect(try reader.read(path: Self.name) == Self.payload)
    }

    @Test("bit-3 entry with an unsigned data descriptor reads identically")
    func readsUnsignedDataDescriptorEntry() throws {
        let reader = try ZipReader(data: Self.archive(withSignature: false))
        #expect(try reader.read(path: Self.name) == Self.payload)
    }
}
