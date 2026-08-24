#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Testing

    /// Serialized parent suite for every test that spins up a real
    /// `AVAudioEngine`.
    ///
    /// CoreAudio's AudioUnit hardware initialization (`AudioUnitInitialize`,
    /// reached via `AVAudioEngine.startAndReturnError`) aborts the entire
    /// test process (`CAVerboseAbort`, surfaced as `EXC_BREAKPOINT`) when
    /// two engines initialize / tear down at the same time. Swift Testing
    /// runs suites in parallel by default, so the audio-engine smoke suites
    /// are nested under this `.serialized` suite. `.serialized` is recursive,
    /// so the nested suites — and therefore their engine lifecycles — never
    /// overlap one another.
    ///
    /// A per-suite `.serialized` only orders a single suite's own tests; it
    /// does NOT stop two *different* suites from overlapping (an async test
    /// holding a running engine across an `await` while another suite starts
    /// its engine), which is what intermittently crashed the run. Sharing
    /// this parent is what removes the cross-suite overlap.
    @Suite(.serialized)
    enum AudioEngineSerial {}
#endif
