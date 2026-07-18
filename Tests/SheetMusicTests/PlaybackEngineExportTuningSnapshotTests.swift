#if !os(Android)
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    extension AudioEngineSerial {
        /// Covers Gap A: `ExportEngineSnapshot` must carry the live engine's
        /// whole-score transpose and master A4 tuning, so the offline export
        /// synths (`PlaybackEngine+Export.buildScoreSynth`) can reproduce the
        /// same key shift / calibration the user hears live. Before this fix
        /// the snapshot dropped both fields and a transposed / detuned score
        /// bounced in the wrong key.
        @Suite("PlaybackEngine export snapshot — transpose + master tuning")
        @MainActor
        struct PlaybackEngineExportTuningSnapshotTests {
            private struct FakeResolver: SoundfontResolver {
                let gmURL: URL?
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    gmURL
                }
            }

            private static func singleStaffScore() -> Score {
                let part = Part(
                    id: "p",
                    instrument: Instrument(
                        id: "i", channels: [InstrumentChannel(program: 0)],
                    ),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                return Score(division: 480, parts: [part])
            }

            @Test("default snapshot is untransposed and at concert pitch")
            func snapshotDefaults() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                let snapshot = engine.exportEngineSnapshot()
                #expect(snapshot.transposeSemitones == 0)
                #expect(snapshot.masterTuningCents == 0)
            }

            @Test("exportEngineSnapshot captures a live transpose")
            func snapshotCapturesTranspose() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setTranspose(semitones: 5)
                #expect(engine.exportEngineSnapshot().transposeSemitones == 5)
            }

            @Test("exportEngineSnapshot captures a negative live transpose")
            func snapshotCapturesNegativeTranspose() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setTranspose(semitones: -7)
                #expect(engine.exportEngineSnapshot().transposeSemitones == -7)
            }

            @Test("exportEngineSnapshot captures a live master-tuning offset")
            func snapshotCapturesTuning() throws { // swiftlint:disable:this inclusive_language
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setMasterTuning(cents: -31.77)
                #expect(engine.exportEngineSnapshot().masterTuningCents == -31.77)
            }

            @Test("exportEngineSnapshot captures transpose and master tuning together")
            func snapshotCapturesBoth() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setTranspose(semitones: -3)
                engine.setMasterTuning(cents: 12.5)
                let snapshot = engine.exportEngineSnapshot()
                #expect(snapshot.transposeSemitones == -3)
                #expect(snapshot.masterTuningCents == 12.5)
            }
        }
    }
#endif
