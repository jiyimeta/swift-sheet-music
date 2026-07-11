#if canImport(CFluidSynth)
    import CFluidSynth
    import Testing

    /// Phase 0 de-risk: proves SwiftPM links Homebrew's libfluidsynth and the
    /// synth actually renders audio. Apple-only; excluded on hosts without the
    /// `CFluidSynth` module (Android, or an Apple build where FluidSynth is not
    /// in the graph).
    struct FluidSynthLinkSmokeTests {
        static let generalUserGS =
            "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/Resources/Soundfonts/GeneralUser-GS.sf2"

        @Test func fluidSynthLinksAndRendersANote() {
            let settings = new_fluid_settings()
            fluid_settings_setnum(settings, "synth.sample-rate", 44100)
            let synth = new_fluid_synth(settings)
            #expect(synth != nil)
            // FluidSynth's default polyphony is 256 (vs AUMIDISynth's hard 64).
            #expect(fluid_synth_get_polyphony(synth) == 256)

            let sfid = fluid_synth_sfload(synth, Self.generalUserGS, 1)
            #expect(sfid >= 0)

            _ = fluid_synth_noteon(synth, 0, 60, 96)
            var left = [Float](repeating: 0, count: 512)
            var right = [Float](repeating: 0, count: 512)
            let rc = fluid_synth_write_float(synth, 512, &left, 0, 1, &right, 0, 1)
            #expect(rc == FLUID_OK)
            #expect(left.contains { $0 != 0 }) // audio was produced

            delete_fluid_synth(synth)
            delete_fluid_settings(settings)
        }
    }
#endif
