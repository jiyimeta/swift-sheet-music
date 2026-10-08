import Foundation
@testable import SheetMusicZip
import Testing

struct DeflateInflateTests {
    @Test(arguments: [0, 1, 1000, 300_000])
    func `inflate undoes compress without being told the size`(count: Int) throws {
        let input = Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 * 31 / 7) })
        #expect(try Deflate.inflate(Deflate.compress(input), limit: count) == input)
    }

    @Test func `garbage does not inflate`() {
        #expect(throws: (any Error).self) { try Deflate.inflate(Data([0xFF, 0xFF, 0xFF, 0xFF]), limit: 1 << 20) }
    }

    @Test func `a truncated deflate stream is refused`() throws {
        let compressed = try Deflate.compress(Data(repeating: 42, count: 300_000))
        #expect(throws: (any Error).self) { try Deflate.inflate(Data(compressed.prefix(2)), limit: 1 << 20) }
    }

    /// 300 KB of one byte deflates to well under a kilobyte; a stream that would decode past its budget stops there.
    @Test(arguments: [0, 1, 299_999])
    func `output past the limit is refused`(limit: Int) throws {
        let compressed = try Deflate.compress(Data(repeating: 42, count: 300_000))
        #expect(compressed.count < 1000)
        #expect(throws: ZipError.self) { try Deflate.inflate(compressed, limit: limit) }
    }
}
