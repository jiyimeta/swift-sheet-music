import Foundation
import SheetMusicMSCX
import Testing

/// What a host sees. This file imports `SheetMusicMSCX` and nothing else on purpose — no
/// `@testable`, no `SheetMusicZip` — because `SheetMusicZip` has no library product, so a package
/// consumer cannot import it. A type it owns cannot appear in `MSCZExtraEntry`'s surface: the entry
/// would be constructible but could never be told to stay uncompressed, which is exactly what a
/// `.pkdrawing` payload needs. `MSCZExtraEntriesTests` cannot catch that regression — it imports
/// the zip module itself.
struct MSCZExtraEntryHostSurfaceTests {
    @Test func aHostCanChooseCompressionWithoutTheZipModule() {
        let stored = MSCZExtraEntry(path: "folino/ink/1.pkdrawing", data: Data([0x00]), compression: .stored)
        let deflated = MSCZExtraEntry(path: "folino/prefs.json", data: Data([0x7B, 0x7D]))
        #expect(stored.compression == .stored)
        #expect(deflated.compression == .deflate)
    }

    @Test func aHostCanRoundTripAnEntryItBuiltItself() throws {
        let entries = [MSCZExtraEntry(path: "folino/a.bin", data: Data([0x01, 0x02]), compression: .stored)]
        let mscz = try MSCZWriter.write(mscxData: Data("<museScore/>".utf8), extraEntries: entries)
        #expect(try MSCZReader.extraEntries(in: mscz) == entries)
    }
}
