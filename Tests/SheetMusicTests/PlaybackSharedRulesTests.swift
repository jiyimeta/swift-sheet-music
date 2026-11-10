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

    @Test("playback plays a channel at its slider, or at nothing while it is silenced")
    func playbackGain() {
        var strip = part(0)
        strip.volume = 0.6
        #expect(strip.playbackGain(soloing: false) == 0.6)
        #expect(strip.playbackGain(soloing: true) == 0)
        strip.isMuted = true
        #expect(strip.playbackGain(soloing: false) == 0)
    }

    @Test("a preview sounds at the slider whatever the mute and solo, until the score plays")
    func previewGain() {
        var muted = part(0, muted: true)
        muted.volume = 0.6
        var shutOut = part(1)
        shutOut.volume = 0.4
        #expect(muted.previewGain(soloing: false, isPlaying: false) == 0.6)
        #expect(shutOut.previewGain(soloing: true, isPlaying: false) == 0.4)
        // While playing it is the music's own channel: opening it would bring the part back in under the music.
        #expect(muted.previewGain(soloing: false, isPlaying: true) == 0)
        #expect(shutOut.previewGain(soloing: true, isPlaying: true) == 0)
        // The slider still counts: a strip pulled to nothing previews at nothing.
        var pulledDown = part(2)
        pulledDown.volume = 0
        #expect(pulledDown.previewGain(soloing: false, isPlaying: false) == 0)
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
