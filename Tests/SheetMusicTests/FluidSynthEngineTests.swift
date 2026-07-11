#if canImport(CFluidSynth)
    import Foundation
    @testable import SheetMusicAudioFluidSynth
    import Testing

    /// Local, copyrighted asset (not committed). Folino's bundled lightweight
    /// SoundFont — the one that provokes AUMIDISynth voice stealing. Tests that
    /// need it are `.enabled(if:)`-gated on its presence, so CI (which lacks the
    /// file) skips them rather than failing.
    let generalUserGSPath =
        "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/Resources/Soundfonts/GeneralUser-GS.sf2"

    var generalUserGSAvailable: Bool {
        FileManager.default.fileExists(atPath: generalUserGSPath)
    }

    extension AudioEngineSerial {
        struct FluidSynthEngineTests {
            @Test(.enabled(if: generalUserGSAvailable))
            func engineRendersNonSilentAudioForANote() {
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
    }
#endif
