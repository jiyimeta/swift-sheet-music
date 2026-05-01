import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing
import ZIPFoundation

@Suite struct MSCZReaderTests {
    @Test func parseMatchesDirectMSCX() throws {
        let mscz = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let msczScore = try MSCZReader.parse(Data(contentsOf: mscz))
        let mscxScore = try MSCXParser.parse(Data(contentsOf: mscx))
        #expect(msczScore == mscxScore)
    }

    @Test func corruptZipThrowsCorruptedContainer() {
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        do {
            _ = try MSCZReader.parse(junk)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .corruptedContainer = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func emptyZipThrowsCorruptedContainer() throws {
        // Build an archive that has no entries at all.
        let archive = try Archive(accessMode: .create)
        let empty = try #require(archive.data)
        do {
            _ = try MSCZReader.parse(empty)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case let .corruptedContainer(reason) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(reason.lowercased().contains("mscx"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func parseContentsOfURLMatchesDataOverload() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let viaData = try MSCZReader.parse(Data(contentsOf: url))
        let viaURL = try MSCZReader.parse(contentsOf: url)
        #expect(viaData == viaURL)
    }

    @Test func parseContentsOfMissingURLThrowsIOError() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-there.mscz")
        do {
            _ = try MSCZReader.parse(contentsOf: missing)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case let .ioError(u, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(u == missing)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func fallbackFileNameRenamedMainEntry() throws {
        // Zip only contains "renamed.mscx" at root — the rule-2 fallback
        // in MSCZReader should still locate it.
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxBytes = try Data(contentsOf: mscx)
        let archive = try Archive(accessMode: .create)
        try archive.addEntry(
            with: "renamed.mscx",
            type: .file,
            uncompressedSize: Int64(mscxBytes.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, mscxBytes.count)
            return mscxBytes.subdata(in: start ..< end)
        }
        let msczBytes = try #require(archive.data)
        let score = try MSCZReader.parse(msczBytes)
        #expect(score.division == 480)
    }
}
