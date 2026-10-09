@testable import SheetMusicAudioWindows
import Testing

struct OfflineEngineTests {
    @Test func anOfflineEngineOpensNoDeviceAndRendersAtItsRate() throws {
        let engine = WindowsPlaybackEngine(
            soundfontResolver: Fixtures.silentResolver, output: .offline(sampleRate: 44100),
        )
        defer { engine.teardown() }
        try engine.prepare(score: Fixtures.score("multiPartMixedStaves"))
        #expect(engine.output == .offline(sampleRate: 44100))
        #expect(engine.deviceStream == nil)
        #expect(engine.diagnostics.hasOutputDevice == false)
        #expect(engine.diagnostics.sampleRate == 44100)
        // Four parts — the piano's two staves are one strip — and the metronome.
        #expect(engine.mixerChannels.count == 5)
    }

    @Test func theDefaultIsTheDevice() {
        let engine = WindowsPlaybackEngine(soundfontResolver: Fixtures.silentResolver)
        #expect(engine.output == .defaultDevice)
    }
}
