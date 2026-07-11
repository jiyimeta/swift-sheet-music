#if canImport(CFluidSynth)
    @testable import SheetMusicAudioFluidSynth
    import Testing

    /// Local, copyrighted asset (not committed). Folino's bundled lightweight
    /// SoundFont — the one that provokes AUMIDISynth voice stealing.
    let generalUserGSPath =
        "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/Resources/Soundfonts/GeneralUser-GS.sf2"

    struct FluidSynthEngineTests {
        @Test func engineRendersNonSilentAudioForANote() {
            let engine = FluidSynthEngine(sampleRate: 44100)
            #expect(engine.loadSoundFont(generalUserGSPath) >= 0)
            engine.programSelect(channel: 0, bank: 0, program: 0)
            engine.noteOn(channel: 0, key: 60, velocity: 96)

            var left = [Float](repeating: 0, count: 512)
            var right = [Float](repeating: 0, count: 512)
            engine.render(frameCount: 512, left: &left, right: &right)

            #expect(left.contains { $0 != 0 })
            #expect(engine.activeVoiceCount >= 1)
        }
    }
#endif
