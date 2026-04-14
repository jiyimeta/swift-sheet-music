import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct VariableLengthQuantityTests {
    @Test func encodeZero() {
        #expect(VariableLengthQuantity.encode(0) == Data([0x00]))
    }
    @Test func encodeSmall() {
        #expect(VariableLengthQuantity.encode(0x40) == Data([0x40]))
        #expect(VariableLengthQuantity.encode(0x7F) == Data([0x7F]))
    }
    @Test func encodeTwoBytes() {
        #expect(VariableLengthQuantity.encode(0x80) == Data([0x81, 0x00]))
        #expect(VariableLengthQuantity.encode(0x2000) == Data([0xC0, 0x00]))
    }
    @Test func encodeRefNoteOffDelta479() {
        #expect(VariableLengthQuantity.encode(479) == Data([0x83, 0x5F]))
    }
    @Test func encodeMaxFourBytes() {
        #expect(VariableLengthQuantity.encode(0x0FFF_FFFF) == Data([0xFF, 0xFF, 0xFF, 0x7F]))
    }
}
