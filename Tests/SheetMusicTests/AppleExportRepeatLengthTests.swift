#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMSCX
    import Testing

    /// An export runs as long as the score plays: to the end of its last beat, and through every repeat. Until
    /// 2026-10-10 it stopped at the onset of the last beat and at the notated length (`repeat52.mscx`, six notated
    /// measures and twenty measure-plays — `RepeatUnwindFixtureTests` — exported 3.45 s of about 12).
    @MainActor
    struct AppleExportRepeatLengthTests {
        @Test func aScoreWithRepeatsExportsItsUnrolledLength() async throws {
            let url = try #require(TestResources.url(forResource: "repeat52", withExtension: "mscx"))
            let score = try MSCXParser.parse(contentsOf: url)
            let engine = PlaybackEngine(soundfontResolver: NoSoundFont())
            try engine.prepare(score: score)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("repeat52-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: out) }
            try await engine.exportAudioFile(to: out, score: score, format: .wav())
            let file = try AVAudioFile(forReading: out)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            #expect(
                seconds > engine.totalTimeSeconds * 2, "exported \(seconds) s, notated \(engine.totalTimeSeconds) s",
            )
        }

        /// One 4/4 bar of rests at 120 bpm: two seconds, with no repeat in the way.
        @Test func aScoreWithoutRepeatsExportsItsWholeLength() async throws {
            let url = try #require(TestResources.url(forResource: "multiPartMixedStaves", withExtension: "mscx"))
            let score = try MSCXParser.parse(contentsOf: url)
            let engine = PlaybackEngine(soundfontResolver: NoSoundFont())
            try engine.prepare(score: score)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: out) }
            try await engine.exportAudioFile(to: out, score: score, format: .wav())
            let file = try AVAudioFile(forReading: out)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            #expect(
                abs(seconds - engine.totalTimeSeconds) < 0.01,
                "exported \(seconds) s, notated \(engine.totalTimeSeconds) s",
            )
        }
    }

    /// A real-`AVAudioEngine` export, so it lives under the serial parent like every such test.
    extension AudioEngineSerial {
        @Suite("Export ends at the last measure-play")
        @MainActor
        struct AppleExportAlFineLengthTests {
            /// D.S. al Fine, 6 measure-plays of 2 s: the export used to run to the notated end, 14 s, with 2 s of
            /// silence after the music.
            @Test func anAlFineScoreEndsAtItsLastMeasurePlay() async throws {
                let score = RepeatPlanFixtures.dalSegnoAlFine()
                let engine = PlaybackEngine(soundfontResolver: NoSoundFont())
                try engine.prepare(score: score)
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alfine-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: out) }
                try await engine.exportAudioFile(to: out, score: score, format: .wav())
                let file = try AVAudioFile(forReading: out)
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                #expect(abs(seconds - 12.0) < 0.01, "exported \(seconds) s")
            }
        }
    }

    private struct NoSoundFont: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
