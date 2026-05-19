import Foundation
@testable import SheetMusicZip
import Testing

@Suite("BinaryCursor")
struct BinaryCursorTests {
    @Test
    func roundTripLEPrimitives() throws {
        var w = BinaryWriter()
        w.writeUInt16LE(0x1234)
        w.writeUInt32LE(0xDEAD_BEEF)
        w.writeBytes(Data([0xAA, 0xBB, 0xCC]))
        let bytes = w.data
        #expect(bytes == Data([
            0x34, 0x12, // uint16
            0xEF, 0xBE, 0xAD, 0xDE, // uint32
            0xAA, 0xBB, 0xCC, // raw
        ]))
        var r = BinaryReader(data: bytes)
        #expect(try r.readUInt16LE() == 0x1234)
        #expect(try r.readUInt32LE() == 0xDEAD_BEEF)
        #expect(try r.readBytes(count: 3) == Data([0xAA, 0xBB, 0xCC]))
        #expect(r.isAtEnd)
    }

    @Test
    func underflowThrows() {
        var r = BinaryReader(data: Data([0x01]))
        #expect(throws: ZipError.self) { try r.readUInt32LE() }
    }

    @Test
    func seekAndPeek() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var r = BinaryReader(data: bytes)
        try r.seek(to: 2)
        #expect(try r.readUInt16LE() == 0x0403)
        #expect(r.cursor == 4)
    }

    @Test
    func readsFromNonZeroStartIndexSlice() throws {
        // Reproduce the ZipReader pattern: construct a slice of a larger
        // Data and feed it to BinaryReader. Without normalization, the
        // underlying Data.subdata(in:) call traps because slice indices
        // are absolute, not 0-based.
        let full = Data([0x99, 0x99, 0x34, 0x12, 0xEF, 0xBE, 0xAD, 0xDE, 0x99])
        let slice = full[2 ..< 8] // startIndex == 2
        var r = BinaryReader(data: slice)
        #expect(try r.readUInt16LE() == 0x1234)
        #expect(try r.readUInt32LE() == 0xDEAD_BEEF)
        #expect(r.isAtEnd)
    }
}
