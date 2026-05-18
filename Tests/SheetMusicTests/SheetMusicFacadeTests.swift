import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct SheetMusicFacadeTests {
    #if !os(Android)
        @Test func loadScoreMSCZData() throws {
            let url = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscz"),
            )
            let bytes = try Data(contentsOf: url)
            let score = try SheetMusic.loadScore(msczData: bytes)
            #expect(score.division == 480)
        }
    #endif

    @Test func loadScoreMSCXData() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
        )
        let bytes = try Data(contentsOf: url)
        let score = try SheetMusic.loadScore(mscxData: bytes)
        #expect(score.parts.count == 1)
        #expect(score.division == 480)
    }

    @Test func loadScoreMSCXURL() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
        )
        let score = try SheetMusic.loadScore(mscxURL: url)
        #expect(score.parts.count == 1)
    }

    #if !os(Android)
        @Test func loadScoreMSCZURL() throws {
            let url = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscz"),
            )
            let score = try SheetMusic.loadScore(msczURL: url)
            #expect(score.parts.count == 1)
        }

        @Test func saveMSCZDataRoundTrip() throws {
            let mscx = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
            )
            let mscxData = try Data(contentsOf: mscx)
            let msczData = try SheetMusic.saveMSCZ(mscxData: mscxData)
            let score = try SheetMusic.loadScore(msczData: msczData)
            let direct = try SheetMusic.loadScore(mscxData: mscxData)
            #expect(score == direct)
        }

        @Test func saveMSCZURLRoundTrip() throws {
            let mscx = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
            )
            let mscxData = try Data(contentsOf: mscx)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("facade-test-\(UUID().uuidString).mscz")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try SheetMusic.saveMSCZ(mscxData: mscxData, to: tmp)
            let score = try SheetMusic.loadScore(msczURL: tmp)
            #expect(score.division == 480)
        }
    #endif

    @Test func loadScoreFromMidiData() throws {
        let bytes = Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00,
        ])
        let score = try SheetMusic.loadScore(midiData: bytes)
        #expect(score.division == 480)
    }

    @Test func loadScoreFromMidiURLUsesFilenameAsTitle() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyMidiSong.mid")
        let bytes = Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00,
        ])
        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let score = try SheetMusic.loadScore(midiURL: tempURL)
        #expect(score.metaTags["workTitle"] == "MyMidiSong")
    }

    // PDF roundtrip tests removed — PDF import is held internal while
    // it's being reworked. See
    // `docs/superpowers/plans/2026-05-03-pdf-import-paused.md`.
}
