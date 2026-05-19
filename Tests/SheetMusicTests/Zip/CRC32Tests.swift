import Foundation
@testable import SheetMusicZip
import Testing

@Suite("CRC32")
struct CRC32Tests {
    /// RFC 1952-style known vectors. CRC32 (initial 0xFFFFFFFF, XOR-out
    /// 0xFFFFFFFF, polynomial 0xEDB88320).
    @Test(arguments: [
        (Data(), UInt32(0x0000_0000)),
        (Data("a".utf8), UInt32(0xE8B7_BE43)),
        (Data("abc".utf8), UInt32(0x3524_41C2)),
        (Data("message digest".utf8), UInt32(0x2015_9D7F)),
        (Data(0 ... 255), UInt32(0x2905_8C73)),
    ])
    func vectors(input: Data, expected: UInt32) {
        #expect(CRC32.compute(input) == expected)
    }

    @Test
    func longParagraph() {
        let s = String(repeating: "Lorem ipsum dolor sit amet, ", count: 100)
        let value = CRC32.compute(Data(s.utf8))
        #expect(value != 0) // smoke: real value, not init constant
    }
}
