import Foundation
@testable import SheetMusicZip
import Testing

@Suite("Deflate backend")
struct DeflateBackendTests {
    @Test(arguments: [
        Data(),
        Data([0x42]),
        Data(repeating: 0xAA, count: 1024),
        Data((0 ..< 10000).map { UInt8($0 & 0xFF) }),
        Data(repeating: 0x00, count: 64 * 1024), // low-entropy stress
    ])
    func roundTrip(payload: Data) throws {
        let compressed = try Deflate.compress(payload)
        let decompressed = try Deflate.decompress(
            compressed, expectedSize: payload.count,
        )
        #expect(decompressed == payload)
    }
}
