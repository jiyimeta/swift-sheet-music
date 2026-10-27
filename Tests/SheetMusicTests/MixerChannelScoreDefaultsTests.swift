@testable import SheetMusicAudioCore
@testable import SheetMusicCore
import Testing

/// What a score replacement that kept every strip does to the mixer, and which edits keep every strip.
struct MixerChannelScoreDefaultsTests {
    private let strip = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)

    private func channel(
        name: String = "Piano", volume: Float = 1, isMuted: Bool = false, isSoloed: Bool = false, program: UInt8 = 0,
    ) -> MixerChannel {
        MixerChannel(id: strip, name: name, volume: volume, isMuted: isMuted, isSoloed: isSoloed, program: program)
    }

    private func twoPartScore(withViolin: Bool = true) -> Score {
        let piano = BlankScoreTemplate.PartPlan(
            instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")], gmProgram: 0,
        )
        let violin = BlankScoreTemplate.PartPlan(
            instrumentID: "violin", longName: "Violin", staves: [.init(clefType: "G")], gmProgram: 40,
        )
        return Score.blank(BlankScoreTemplate(
            title: "Mix",
            parts: withViolin ? [piano, violin] : [piano],
            measureCount: 1,
        ))
    }

    @Test("a setting the score changed is taken from it")
    func changedSettingIsTaken() {
        let live = [channel(volume: 0.3, isMuted: true, program: 5)]

        let updated = live.takingChangedDefaults(
            from: [channel(volume: 1, isMuted: false, program: 0)],
            to: [channel(volume: 0.5, isMuted: false, program: 0)],
        )

        #expect(updated == [channel(volume: 0.5, isMuted: true, program: 5)])
    }

    @Test("every setting the score changed is taken, and the names follow it")
    func everyChangedSettingIsTaken() {
        let live = [channel(volume: 0.3, isMuted: false, isSoloed: false, program: 5)]

        let updated = live.takingChangedDefaults(
            from: [channel()],
            to: [channel(name: "Guitar", volume: 0.8, isMuted: true, isSoloed: true, program: 24)],
        )

        #expect(updated == [channel(name: "Guitar", volume: 0.8, isMuted: true, isSoloed: true, program: 24)])
    }

    @Test("an unchanged score leaves the listener's mix alone")
    func unchangedScoreKeepsMix() {
        let live = [channel(volume: 0.3, isMuted: true, program: 5), MixerChannel(id: .metronome, name: "Metronome")]

        let updated = live.takingChangedDefaults(
            from: [channel(), MixerChannel(id: .metronome, name: "Metronome")],
            to: [channel(), MixerChannel(id: .metronome, name: "Metronome")],
        )

        #expect(updated == live)
    }

    @Test("a part's own level, sound, mute, solo and names keep the channels")
    func mixEditKeepsChannels() {
        let original = twoPartScore()
        var edited = original
        edited.parts.updateValue(at: 1) { part in
            part.instrument.longName = "Viola"
            part.instrument.channels[0].volume = 64
            part.instrument.channels[0].program = 41
            part.instrument.channels[0].isMuted = true
            part.instrument.channels[0].isSoloed = true
        }

        let before = PlaybackChannelLayout(score: original)
        let after = PlaybackChannelLayout(score: edited)

        #expect(before != after)
        #expect(before.hasSameChannels(as: after))
    }

    @Test("a part that becomes a drum kit changes the channels")
    func drumEditChangesChannels() {
        let original = twoPartScore()
        var edited = original
        edited.parts.updateValue(at: 1) { $0.instrument.useDrumset = true }

        #expect(!PlaybackChannelLayout(score: original).hasSameChannels(as: PlaybackChannelLayout(score: edited)))
    }

    @Test("a part removed changes the channels")
    func removedPartChangesChannels() {
        let original = twoPartScore()
        let edited = twoPartScore(withViolin: false)

        #expect(!PlaybackChannelLayout(score: original).hasSameChannels(as: PlaybackChannelLayout(score: edited)))
    }
}
