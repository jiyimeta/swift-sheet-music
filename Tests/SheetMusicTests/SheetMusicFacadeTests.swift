import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct SheetMusicFacadeTests {
    @Test func loadScoreMSCZData() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let bytes = try Data(contentsOf: url)
        let score = try SheetMusic.loadScore(msczData: bytes)
        #expect(score.division == 480)
    }

    @Test func loadScoreMSCXData() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let bytes = try Data(contentsOf: url)
        let score = try SheetMusic.loadScore(mscxData: bytes)
        #expect(score.parts.count == 1)
        #expect(score.division == 480)
    }

    @Test func loadScoreMSCXURL() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let score = try SheetMusic.loadScore(mscxURL: url)
        #expect(score.parts.count == 1)
    }

    @Test func loadScoreMSCZURL() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscz")
        )
        let score = try SheetMusic.loadScore(msczURL: url)
        #expect(score.parts.count == 1)
    }

    @Test func saveMSCZDataRoundTrip() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let msczData = try SheetMusic.saveMSCZ(mscxData: mscxData)
        let score = try SheetMusic.loadScore(msczData: msczData)
        let direct = try SheetMusic.loadScore(mscxData: mscxData)
        #expect(score == direct)
    }

    @Test func saveMSCZURLRoundTrip() throws {
        let mscx = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx")
        )
        let mscxData = try Data(contentsOf: mscx)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("facade-test-\(UUID().uuidString).mscz")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try SheetMusic.saveMSCZ(mscxData: mscxData, to: tmp)
        let score = try SheetMusic.loadScore(msczURL: tmp)
        #expect(score.division == 480)
    }
}
