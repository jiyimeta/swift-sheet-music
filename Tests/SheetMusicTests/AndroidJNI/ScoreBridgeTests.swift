import Foundation
@testable import SheetMusicAndroidJNI
import Testing

struct ScoreBridgeTests {
    @Test
    func loadFromMSCXBytesProducesScore() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01",
            withExtension: "mscx",
        ))
        let bytes = try Data(contentsOf: url)
        let score = try ScoreBridge.loadScore(bytes: bytes)
        #expect(!score.parts.isEmpty)
    }

    @Test
    func loadFromMSCZBytesProducesScore() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01",
            withExtension: "mscz",
        ))
        let bytes = try Data(contentsOf: url)
        let score = try ScoreBridge.loadScore(bytes: bytes)
        #expect(!score.parts.isEmpty)
    }

    @Test
    func loadFromGarbageThrows() {
        #expect(throws: Error.self) {
            _ = try ScoreBridge.loadScore(bytes: Data("not a score".utf8))
        }
    }
}
