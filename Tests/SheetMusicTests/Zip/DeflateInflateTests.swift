import Foundation
@testable import SheetMusicZip
import Testing

struct DeflateInflateTests {
    @Test(arguments: [0, 1, 1000, 300_000])
    func `inflate undoes compress without being told the size`(count: Int) throws {
        let input = Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 * 31 / 7) })
        #expect(try Deflate.inflate(Deflate.compress(input)) == input)
    }

    @Test func `garbage does not inflate`() {
        #expect(throws: (any Error).self) { try Deflate.inflate(Data([0xFF, 0xFF, 0xFF, 0xFF])) }
    }

    @Test func `a truncated deflate stream is refused`() throws {
        let compressed = try Deflate.compress(Data(repeating: 42, count: 300_000))
        #expect(throws: (any Error).self) { try Deflate.inflate(Data(compressed.prefix(2))) }
    }
}
