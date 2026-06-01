import Foundation
@testable import SheetMusicAudioCore
import Testing

struct LittleEndianWriterTests {
    @Test func writesLittleEndianIntegers() {
        var w = LittleEndianWriter()
        w.appendUInt8(0xAB)
        w.appendUInt16(0x1234)
        w.appendUInt32(0x89AB_CDEF)
        #expect(Array(w.data) == [
            0xAB,
            0x34, 0x12,
            0xEF, 0xCD, 0xAB, 0x89,
        ])
    }

    @Test func writesSignedInt16TwosComplement() {
        var w = LittleEndianWriter()
        w.appendInt16(-1)
        w.appendInt16(-32768)
        #expect(Array(w.data) == [0xFF, 0xFF, 0x00, 0x80])
    }

    @Test func appendsFourByteTag() {
        var w = LittleEndianWriter()
        w.appendTag("RIFF")
        #expect(Array(w.data) == Array("RIFF".utf8))
    }

    @Test func fixedStringZeroPadsAndTruncates() {
        var w = LittleEndianWriter()
        w.appendFixedString("AB", length: 4)
        w.appendFixedString("TOOLONGNAME", length: 4)
        #expect(Array(w.data) == [
            0x41, 0x42, 0x00, 0x00,
            0x54, 0x4F, 0x4F, 0x4C,
        ])
    }
}
