#if !os(Android)
    import AVFoundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMSCX
    import Testing

    @Suite("PlaybackState .exporting")
    struct PlaybackStateExportingCaseTests {
        @Test(".exporting is a distinct case")
        func exportingIsDistinct() {
            let s: PlaybackState = .exporting
            #expect(s == .exporting)
            #expect(s != .playing)
            #expect(s != .paused)
            #expect(s != .stopped)
        }
    }

    @Suite("PCMAudioExportWriter")
    struct PCMAudioExportWriterTests {
        /// Writing one buffer of silence to a .wav and reading it back
        /// yields the expected sample rate / channels / frame count.
        @Test("WAV writer round-trip")
        func wavRoundTrip() async throws {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("smwriter-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            let options = PCMOptions(sampleRate: 22050, bitDepth: .int16, channels: .mono)
            let writer = try PCMAudioExportWriter(
                url: url, format: .wav(options),
            )

            let inFmt = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 22050,
                channels: 1,
                interleaved: false,
            ))
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 1024))
            buf.frameLength = 1024

            try await writer.write(buf)
            try await writer.finish()

            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 22050)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.length == 1024)
        }

        @Test("AIFF writer round-trip")
        func aiffRoundTrip() async throws {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("smwriter-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: url) }

            let writer = try PCMAudioExportWriter(
                url: url, format: .aiff(PCMOptions()),
            )
            let inFmt = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100,
                channels: 2,
                interleaved: false,
            ))
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 512))
            buf.frameLength = 512
            try await writer.write(buf)
            try await writer.finish()

            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 44100)
            #expect(file.fileFormat.channelCount == 2)
            #expect(file.length == 512)
        }
    }

    @Suite("CompressedAudioExportWriter (M4A)")
    struct CompressedAudioExportWriterTests {
        @Test("M4A writer produces an AAC file")
        func m4aRoundTrip() async throws {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("smwriter-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }

            let writer = try CompressedAudioExportWriter(
                url: url, format: .m4a(CompressedOptions(bitRate: 128_000)),
            )
            let inFmt = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100,
                channels: 2,
                interleaved: false,
            ))
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096))
            buf.frameLength = 4096
            try await writer.write(buf)
            try await writer.finish()

            let file = try AVAudioFile(forReading: url)
            let desc = file.fileFormat.streamDescription.pointee
            #expect(desc.mFormatID == kAudioFormatMPEG4AAC)
        }
    }

    @Suite("MP3AudioExportWriter")
    struct MP3AudioExportWriterTests {
        /// On macOS, AVAssetWriter does not support the .mp3 file type at runtime,
        /// so MP3AudioExportWriter throws .formatUnsupportedOnThisOS rather than
        /// crashing via NSException. The round-trip write path is iOS/tvOS-only.
        @Test("MP3 writer throws .formatUnsupportedOnThisOS on macOS")
        @available(macOS 14, *)
        func mp3UnsupportedOnMacOS() throws {
            #if os(macOS)
                let url = FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent("smwriter-\(UUID().uuidString).mp3")
                defer { try? FileManager.default.removeItem(at: url) }
                let format = AudioFileFormat.mp3(CompressedOptions(bitRate: 128_000))
                #expect(throws: AudioExportError.formatUnsupportedOnThisOS(format)) {
                    try MP3AudioExportWriter(url: url, format: format)
                }
            #endif
        }

        @Test("MP3 writer produces an MP3 file (iOS 17+ / tvOS 17+)")
        func mp3RoundTrip() async throws {
            #if os(iOS) || os(tvOS)
                guard #available(iOS 17, tvOS 17, *) else { return }
                let url = FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent("smwriter-\(UUID().uuidString).mp3")
                defer { try? FileManager.default.removeItem(at: url) }

                let writer = try MP3AudioExportWriter(
                    url: url, format: .mp3(CompressedOptions(bitRate: 128_000)),
                )
                let inFmt = try #require(AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 44100,
                    channels: 2,
                    interleaved: false,
                ))
                let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096))
                buf.frameLength = 4096
                try await writer.write(buf)
                try await writer.finish()

                #expect(FileManager.default.fileExists(atPath: url.path))
                let file = try AVAudioFile(forReading: url)
                #expect(file.length > 0)
            #endif
        }
    }

    @Suite("AudioFileExporter writer factory")
    struct AudioFileExporterFactoryTests {
        @Test("Factory picks PCM writer for .wav")
        func picksPCMForWav() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smfactory-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AudioFileExporter
                .makeWriter(url: url, format: .wav())
            #expect(writer is PCMAudioExportWriter)
        }

        @Test("Factory picks Compressed writer for .m4a")
        func picksCompressedForM4a() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smfactory-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AudioFileExporter
                .makeWriter(url: url, format: .m4a())
            #expect(writer is CompressedAudioExportWriter)
        }

        @Test("Factory throws .formatUnsupportedOnThisOS for .mp3 on macOS")
        func mp3UnsupportedOnMacOS() throws {
            #if os(macOS)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("smfactory-\(UUID().uuidString).mp3")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    _ = try AudioFileExporter
                        .makeWriter(url: url, format: .mp3())
                    Issue.record("Expected throw on macOS")
                } catch AudioExportError.formatUnsupportedOnThisOS {
                    // ok
                }
            #endif
        }
    }

    /// Silent resolver — returns nil for everything. Sampler stays
    /// silent but the offline rendering loop still produces valid
    /// silent buffers, which is what these tests verify (we don't do
    /// byte-level audio comparison).
    private struct SilentResolver: SoundfontResolver {
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }

    private func loadMidi01() throws -> Score {
        guard let url = Bundle.module.url(
            forResource: "midi01", withExtension: "mscx",
        ) else {
            struct MissingFixture: Error {}
            throw MissingFixture()
        }
        return try MSCXParser.parse(contentsOf: url)
    }

    @Suite("PlaybackEngine.exportAudioFile (integration)")
    @MainActor
    struct PlaybackEngineExportTests {
        @Test("WAV export produces a readable file with correct format")
        func wavSmoke() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            try await engine.exportAudioFile(
                to: url,
                score: score,
                format: .wav(PCMOptions(sampleRate: 22050, bitDepth: .int16, channels: .stereo)),
            )

            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 22050)
            #expect(file.fileFormat.channelCount == 2)
            #expect(file.length > 0)
            #expect(engine.state == .stopped)
        }

        @Test("AIFF export round-trips")
        func aiffSmoke() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: url) }

            try await engine.exportAudioFile(
                to: url, score: score, format: .aiff(),
            )
            let file = try AVAudioFile(forReading: url)
            #expect(file.length > 0)
        }

        @Test("M4A export round-trips and reports format ID AAC")
        func m4aSmoke() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }

            try await engine.exportAudioFile(
                to: url, score: score, format: .m4a(),
            )
            let file = try AVAudioFile(forReading: url)
            let desc = file.fileFormat.streamDescription.pointee
            #expect(desc.mFormatID == kAudioFormatMPEG4AAC)
        }

        @Test("Range export is shorter than full export")
        func rangeNarrowing() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)

            // Full export
            let fullURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: fullURL) }
            try await engine.exportAudioFile(
                to: fullURL, score: score, format: .wav(),
            )
            let fullFrames = try AVAudioFile(forReading: fullURL).length

            // Half-score export: first two beats of measure 0 (ticks 0–960
            // in this 4/4 480-division score). midi01 has one measure only,
            // so we split it in half instead of using measureIndex: 1.
            let firstCursor: ScoreCursor = .beat(measureIndex: 0, tickInMeasure: 0)
            let halfMeasureCursor: ScoreCursor = .beat(measureIndex: 0, tickInMeasure: 960)
            let regionURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: regionURL) }
            try await engine.exportAudioFile(
                to: regionURL,
                score: score,
                format: .wav(),
                range: .region(from: firstCursor, to: halfMeasureCursor),
            )
            let regionFrames = try AVAudioFile(forReading: regionURL).length
            #expect(regionFrames < fullFrames)
            #expect(regionFrames > 0)
        }

        @Test("Throws .noScorePrepared when prepare wasn't called")
        func errorNoScorePrepared() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            // intentionally skip prepare

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            do {
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )
                Issue.record("Expected throw")
            } catch AudioExportError.noScorePrepared {
                // ok
            }
        }

        @Test("Cancellation removes the partial file")
        func cancellationCleansUp() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            let task = Task { @MainActor in
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )
            }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Expected cancellation throw")
            } catch is CancellationError {
                // ok
            } catch AudioExportError.cancelled {
                // ok
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(engine.state == .stopped)
        }
    }
#endif
