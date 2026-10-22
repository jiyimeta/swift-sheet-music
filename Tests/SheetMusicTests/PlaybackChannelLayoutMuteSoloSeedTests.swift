@testable import SheetMusicAudioCore
@testable import SheetMusicCore
import Testing

/// The live mixer starts from the score's own channel mute / solo rather than from "everything audible".
struct PlaybackChannelLayoutMuteSoloSeedTests {
    private func twoPartScore() -> Score {
        Score.blank(BlankScoreTemplate(
            title: "Seed",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")], gmProgram: 0),
                .init(instrumentID: "violin", longName: "Violin", staves: [.init(clefType: "G")], gmProgram: 40),
            ],
            measureCount: 1,
        ))
    }

    private func channel(_ layout: PlaybackChannelLayout, part: Int) throws -> MixerChannel {
        try #require(layout.mixerChannels.first { $0.id == .instrument(partIndex: part, ordinal: 0) })
    }

    @Test func scoreSoloSeedsTheMixer() throws {
        var score = twoPartScore()
        score.parts.updateValue(at: 1) { $0.instrument.channels[0].isSoloed = true }
        let layout = PlaybackChannelLayout(score: score)
        #expect(try channel(layout, part: 1).isSoloed)
        #expect(try !channel(layout, part: 0).isSoloed)
        #expect(layout.mixerChannels.isSoloing)
    }

    @Test func scoreMuteSeedsTheMixer() throws {
        var score = twoPartScore()
        score.parts.updateValue(at: 0) { $0.instrument.channels[0].isMuted = true }
        let layout = PlaybackChannelLayout(score: score)
        #expect(try channel(layout, part: 0).isMuted)
        #expect(try !channel(layout, part: 1).isMuted)
    }

    @Test func untouchedScoreStartsAudible() {
        let layout = PlaybackChannelLayout(score: twoPartScore())
        #expect(layout.mixerChannels.allSatisfy { !$0.isMuted && !$0.isSoloed })
    }
}
