import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct MSCZWriterTests {
    @Test func roundTripDefaultMainName() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let msczData = try MSCZWriter.write(mscxData: mscxData)
        let score = try MSCZReader.parse(msczData)
        let direct = try MSCXParser.parse(mscxData)
        #expect(score == direct)
    }

    @Test func roundTripCustomMainName() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let msczData = try MSCZWriter.write(
            mscxData: mscxData,
            mainFileName: "renamed.mscx"
        )
        // Must round-trip via the reader's rule-2 fallback.
        let score = try MSCZReader.parse(msczData)
        #expect(score.division == 480)
    }

    @Test func emptyMainNameThrows() {
        let bytes = Data([0x3C, 0x78, 0x6D, 0x6C]) // "<xml"
        do {
            _ = try MSCZWriter.write(mscxData: bytes, mainFileName: "")
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

    @Test func nestedMainNameThrows() {
        let bytes = Data([0x3C, 0x78, 0x6D, 0x6C])
        do {
            _ = try MSCZWriter.write(mscxData: bytes, mainFileName: "sub/a.mscx")
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

    @Test func writeToURLThenReadBack() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mscz-writer-test-\(UUID().uuidString).mscz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try MSCZWriter.write(mscxData: mscxData, to: tmp)
        let score = try MSCZReader.parse(contentsOf: tmp)
        let direct = try MSCXParser.parse(mscxData)
        #expect(score == direct)
    }

    @Test func writeToBadURLThrowsIOError() {
        let bogus = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.mscz")
        do {
            try MSCZWriter.write(mscxData: Data([0x3C, 0x78]), to: bogus)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case .ioError(let u, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(u == bogus)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
