import Foundation
@testable import SheetMusicZip
import Testing

@Suite("ZipWriter")
struct ZipWriterTests {
    @Test
    func singleEntryRoundTrips() throws {
        let payload = Data("the quick brown fox".utf8)
        var writer = ZipWriter()
        try writer.add(path: "foo.txt", data: payload, method: .deflate)
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        #expect(reader.entries.count == 1)
        let bytes = try reader.read(path: "foo.txt")
        #expect(bytes == payload)
    }

    @Test
    func storedRoundTrips() throws {
        let payload = Data("plain bytes".utf8)
        var writer = ZipWriter()
        try writer.add(path: "raw.bin", data: payload, method: .stored)
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        let bytes = try reader.read(path: "raw.bin")
        #expect(bytes == payload)
        #expect(reader.entries["raw.bin"]?.method == .stored)
    }
}
