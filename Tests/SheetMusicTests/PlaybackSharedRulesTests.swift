@testable import SheetMusicAudioCore
import Testing

/// The mixer and tuning rules every engine shares (`MixerChannel.isSilenced`, `isSoloing`,
/// `MasterTuning.effectiveCents`).
@Suite("Playback shared rules")
struct PlaybackSharedRulesTests {
    private func part(_ index: Int, muted: Bool = false, soloed: Bool = false) -> MixerChannel {
        MixerChannel(id: .instrument(partIndex: index, ordinal: 0), name: "P\(index)", isMuted: muted, isSoloed: soloed)
    }

    @Test("an instrument is silent when muted, or when another is soloed and it is not")
    func instrumentAudibility() {
        #expect(part(0, muted: true).isSilenced(soloing: false))
        #expect(!part(0).isSilenced(soloing: false))
        #expect(part(0).isSilenced(soloing: true))
        #expect(!part(0, soloed: true).isSilenced(soloing: true))
        // Mute wins over solo in playback.
        #expect(part(0, muted: true, soloed: true).isSilenced(soloing: true))
    }

    @Test("the metronome answers to its own mute alone")
    func metronomeOffTheSoloBus() {
        let click = MixerChannel(id: .metronome, name: "Click")
        #expect(!click.isSilenced(soloing: true))
        #expect(MixerChannel(id: .metronome, name: "Click", isMuted: true).isSilenced(soloing: false))
    }

    @Test("only a soloed channel on the solo bus engages it")
    func soloBus() {
        #expect([part(0), part(1, soloed: true)].isSoloing)
        #expect(![part(0), MixerChannel(id: .metronome, name: "Click", isSoloed: true)].isSoloing)
    }

    @Test("a melodic channel takes calibration plus transposition, percussion the calibration alone")
    func effectiveCents() {
        #expect(MasterTuning.effectiveCents(tuning: 10, transposeSemitones: 2, isPercussion: false) == 210)
        #expect(MasterTuning.effectiveCents(tuning: 10, transposeSemitones: 2, isPercussion: true) == 10)
        #expect(MasterTuning.effectiveCents(tuning: -5, transposeSemitones: -1, isPercussion: false) == -105)
    }
}
