#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore

    /// A `SynthBackend` written only for tests. Adopting this instead of `SynthBackend` gives a transport-only
    /// double the members below without spelling them out in every suite.
    ///
    /// These are test conveniences, not protocol defaults: `SynthBackend` itself has none for these members, so a
    /// production backend still has to implement every one of them. Keep the extension constrained to this marker —
    /// an extension on `SynthBackend` would hand the same answers to real backends too.
    @MainActor
    protocol SynthBackendTestDouble: SynthBackend {}

    extension SynthBackendTestDouble {
        /// Starts the transport without a count-in, so a double that records `play()` still sees the start.
        func play(afterCountInSeconds _: TimeInterval) {
            play()
        }

        /// The double renders no metronome, so there is nothing to turn down.
        func setMetronomeVolume(_: Float) {}

        /// The double maps ticks itself (or not at all); the engine's projection is dropped.
        func setUnrolledTimeMap(_: UnrolledTimeMap) {}

        /// The double cannot render offline, so an export falls back to the built-in AUMIDISynth pipeline.
        func makeOfflineInstance(sampleRate _: Double) -> (any SynthBackend)? {
            nil
        }
    }
#endif
