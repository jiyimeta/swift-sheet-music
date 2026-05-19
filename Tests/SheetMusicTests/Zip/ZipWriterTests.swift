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

    @Test(arguments: [
        ("empty.bin", Data()),
        ("one.bin", Data([0x42])),
        ("small.bin", Data(repeating: 0xAA, count: 1024)),
        ("zeros.bin", Data(repeating: 0, count: 64 * 1024)),
        ("counter.bin", Data((0 ..< 10000).map { UInt8($0 & 0xFF) })),
    ])
    func roundTripVariousSizesAndPatterns(name: String, payload: Data) throws {
        var writer = ZipWriter()
        try writer.add(path: name, data: payload, method: .deflate)
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        #expect(try reader.read(path: name) == payload)
    }

    @Test
    func multipleEntries() throws {
        var writer = ZipWriter()
        try writer.add(path: "a.txt", data: Data("alpha".utf8), method: .deflate)
        try writer.add(path: "b.txt", data: Data("beta".utf8), method: .stored)
        try writer.add(path: "nested/c.txt", data: Data("gamma".utf8), method: .deflate)
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        #expect(reader.entries.count == 3)
        #expect(try reader.read(path: "a.txt") == Data("alpha".utf8))
        #expect(try reader.read(path: "b.txt") == Data("beta".utf8))
        #expect(try reader.read(path: "nested/c.txt") == Data("gamma".utf8))
    }

    @Test
    func emptyArchiveFinishes() throws {
        let writer = ZipWriter()
        let archive = writer.finish()
        let reader = try ZipReader(data: archive)
        #expect(reader.entries.isEmpty)
    }
}
