@testable import SheetMusicCore
import Testing

struct StaffAddressTests {
    @Test func ordering() {
        let a = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let b = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let c = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(a < b)
        #expect(b < c)
        #expect(a < c)
        // Irreflexivity: an address is never less than itself.
        let aCopy = a
        #expect(!(a < aCopy))
    }

    @Test func equality() {
        let x = StaffAddress(partIndex: 2, staffIndexInPart: 1)
        let y = StaffAddress(partIndex: 2, staffIndexInPart: 1)
        #expect(x == y)
        #expect(x.hashValue == y.hashValue)
    }
}
