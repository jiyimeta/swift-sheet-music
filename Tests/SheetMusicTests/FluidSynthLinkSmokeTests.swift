#if canImport(CFluidSynth)
    import CFluidSynth
    import Testing

    /// Phase 0 de-risk: proves SwiftPM links Homebrew's libfluidsynth and the
    /// synth instantiates + renders. Asset-free, so it runs on CI (which
    /// installs `fluid-synth`) and actually guards the link. Apple-only;
    /// excluded where the `CFluidSynth` module is absent (Android).
    ///
    /// Nested under `AudioEngineSerial`: concurrent `fluid_synth` instances race
    /// on FluidSynth's process-global init and crash the test process, so all
    /// FluidSynth suites run serialized (like the real-`AVAudioEngine` suites).
    extension AudioEngineSerial {
        struct FluidSynthLinkSmokeTests {
            @Test func fluidSynthLinksAndRendersSilence() {
                let settings = new_fluid_settings()
                fluid_settings_setnum(settings, "synth.sample-rate", 44100)
                let synth = new_fluid_synth(settings)
                #expect(synth != nil)
                // FluidSynth's default polyphony is 256 (vs AUMIDISynth's hard
                // 64) — the whole reason for this backend.
                #expect(fluid_synth_get_polyphony(synth) == 256)

                // Render a block with no SoundFont loaded: exercises the render
                // path (and hence the link) without needing an asset. We only
                // assert the call succeeds — with no preset the buffer content
                // is unspecified (FluidSynth may leave it untouched).
                var left = [Float](repeating: 0, count: 512)
                var right = [Float](repeating: 0, count: 512)
                let rc = fluid_synth_write_float(synth, 512, &left, 0, 1, &right, 0, 1)
                #expect(rc == FLUID_OK)

                delete_fluid_synth(synth)
                delete_fluid_settings(settings)
            }
        }
    }
#endif
