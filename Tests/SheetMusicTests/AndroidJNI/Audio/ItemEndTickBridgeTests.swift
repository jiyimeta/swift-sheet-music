#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing

    private func loadFixtureScore() throws -> Score {
        let url = try #require(Bundle.module.url(
            forResource: "midi01",
            withExtension: "mscx",
        ))
        let bytes = try Data(contentsOf: url)
        return try ScoreBridge.loadScore(bytes: bytes)
    }

    struct ItemEndTickBridgeTests {
        @Test func returnsEndTickForKnownNote() throws {
            let score = try loadFixtureScore()
            let timeline = PlaybackTimeline(score: score)
            let (id, expectedEndTick) = try #require(
                timeline.itemEndTicks.first(where: {
                    if case .note = $0.key { return true } else { return false }
                }),
            )
            let result = AudioMidiBridge.itemEndTick(score: score, id: id)
            #expect(result == Int64(expectedEndTick))
        }

        @Test func returnsMinusOneForUnknownItem() throws {
            let score = try loadFixtureScore()
            let bogus = ScoreItemID.rest(.init(
                staff: .init(partIndex: 99, staffIndexInPart: 0),
                measureIndex: 999,
                voiceIndex: 0,
                elementIndex: 0,
            ))
            let result = AudioMidiBridge.itemEndTick(score: score, id: bogus)
            #expect(result == -1)
        }
    }
#endif
