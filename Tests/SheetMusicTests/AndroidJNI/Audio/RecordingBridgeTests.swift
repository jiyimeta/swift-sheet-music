#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT && SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicAudioCore
    import Testing

    /// The recording entry points Kotlin's `SwiftySynthDriver` and `RecordingPcmDecoder` call, driven as Kotlin drives
    /// them, and the cache writer behind the decoder.
    struct RecordingBridgeTests {
        private static func temporaryDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @Test func `the writer writes the cache format, mono on both channels, header last`() throws {
            let directory = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let writer = try RecordingPCMCacheWriter(directory: directory.path, cacheKey: "take", sampleRate: 44100.4)
            let mono: [Int16] = [100, -200, 300]
            let stereo: [Int16] = [1, 2, 3, 4]
            try mono.withUnsafeBufferPointer { buffer in
                try writer.append(mono: #require(buffer.baseAddress), frameCount: 3)
            }
            try stereo.withUnsafeBufferPointer { buffer in
                try writer.append(interleavedStereo: #require(buffer.baseAddress), frameCount: 2)
            }
            // Until it finishes there is no file under the final name.
            #expect(!FileManager.default.fileExists(atPath: writer.destinationPath))
            let path = try writer.finish()

            #expect(path == directory.appendingPathComponent("take-44100.pcm").path)
            let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
            #expect(bytes.count == 16 + 5 * 4)
            #expect(Array(bytes[0 ..< 4]) == Array("SMPC".utf8))
            let recording = try MappedRecording(path: path)
            #expect(abs(recording.durationSeconds - 5 / 44100) < 1e-12)
            let frames = recording.frames
            #expect(frames.base[0] == 100 && frames.base[1] == 100)
            #expect(frames.base[2] == -200 && frames.base[3] == -200)
            #expect(Array(UnsafeBufferPointer(start: frames.base + 6, count: 4)) == [1, 2, 3, 4])
            #expect(RecordingPCMCacheWriter.existingFile(directory: directory.path, cacheKey: "take", sampleRate: 44100)
                == path)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["take-44100.pcm"])
        }

        @Test func `a writer with nothing written fails and leaves no file`() throws {
            let directory = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let writer = try RecordingPCMCacheWriter(directory: directory.path, cacheKey: "empty", sampleRate: 48000)
            #expect(throws: RecordingPCMCacheWriter.Failure.invalidLength(frames: 0)) { try writer.finish() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(throws: RecordingPCMCacheWriter.Failure.invalidSampleRate) {
                try RecordingPCMCacheWriter(directory: directory.path, cacheKey: "x", sampleRate: .nan)
            }
        }

        @Test func `the JNI writer entry points open, append, finish and find the file again`() throws {
            let directory = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(nativeRecordingCacheExisting(directory: directory.path, cacheKey: "k", sampleRate: 48000).isEmpty)
            let handle = nativeRecordingCacheWriterOpen(directory: directory.path, cacheKey: "k", sampleRate: 48000)
            #expect(handle != 0)
            let samples: [Int16] = [5, 6, 7, 8]
            let appended = try samples.withUnsafeBufferPointer { buffer in
                try recordingCacheWriterAppend(
                    handle: handle, samples: #require(buffer.baseAddress), frameCount: 2, channels: 2,
                )
            }
            #expect(appended == 0)
            let path = nativeRecordingCacheWriterFinish(handle: handle)
            #expect(path.hasSuffix("/k-48000.pcm"))
            #expect(nativeRecordingCacheExisting(directory: directory.path, cacheKey: "k", sampleRate: 48000) == path)
        }

        @Test func `a track list commits when every file maps, and a missing one leaves the tracks alone`() throws {
            let file = try PCMCacheFixture.write(rate: 48000, frames: 4800) { _ in 8000 }
            defer { try? FileManager.default.removeItem(at: file) }
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            defer { nativeSynthRelease(handle: synth) }

            nativeSynthRecordingsClear(handle: synth)
            nativeSynthRecordingsStage(
                handle: synth, id: "a", pcmPath: file.path, offsetSeconds: 0, transposeSemitones: 0, volume: 1,
                muted: false, soloed: false,
            )
            #expect(nativeSynthRecordingsCommit(handle: synth, soloing: false, readerTransposeSemitones: 0) == 0)
            let staging = RecordingBridge.staging(synth)
            #expect(staging.deck.tracks.map(\.track.id) == ["a"])

            nativeSynthRecordingsClear(handle: synth)
            nativeSynthRecordingsStage(
                handle: synth, id: "b", pcmPath: "/nonexistent.pcm", offsetSeconds: 0, transposeSemitones: 0, volume: 1,
                muted: false, soloed: false,
            )
            #expect(nativeSynthRecordingsCommit(handle: synth, soloing: false, readerTransposeSemitones: 0) == -1)
            #expect(staging.deck.tracks.map(\.track.id) == ["a"], "the playing tracks are left as they were")
        }

        @Test func `an alignment commits, and spans that overlap are refused`() throws {
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            defer { nativeSynthRelease(handle: synth) }
            let sequence = try nativeSequenceCreate(
                synthHandle: synth, smf: HostedSynthFixtures.smf(tempos: [(0, 120)], notes: [(0, 0, 60, 3840)]),
            )
            defer { nativeSequenceRelease(handle: sequence) }

            nativeSynthAlignmentClear(handle: synth)
            nativeSynthAlignmentAddSpan(handle: synth, start: 0, end: 2, duration: 4)
            nativeSynthAlignmentAddSegment(handle: synth, trackId: "", sourceStart: 0, sourceEnd: 10, outputStart: 0)
            #expect(nativeSynthAlignmentCommit(handle: synth) == 0)
            // Tick 960 is transport second 1 at 120 BPM, warped to 2 s at half speed, and back.
            #expect(abs(nativeSynthOutputSecondsAtTick(handle: synth, tick: 960) - 2) < 1e-6)
            #expect(nativeSynthTickAtOutputSeconds(handle: synth, seconds: 2) == 960)
            #expect(nativeSynthCountInSpeed(handle: synth, seconds: 2) == 0.5)
            #expect(abs(nativeSynthCountInDuration(handle: synth, seconds: 2) - 4) < 1e-9)

            nativeSynthAlignmentClear(handle: synth)
            nativeSynthAlignmentAddSpan(handle: synth, start: 0, end: 2, duration: 4)
            nativeSynthAlignmentAddSpan(handle: synth, start: 1, end: 3, duration: 2)
            #expect(nativeSynthAlignmentCommit(handle: synth) == -1)
            #expect(abs(nativeSynthOutputSecondsAtTick(handle: synth, tick: 960) - 2) < 1e-6, "nothing changed")
        }

        /// Spans as Kotlin's `PlaybackTimeWarpSpan.encode` writes them: three big-endian Float64 each.
        private static func encoded(_ spans: [(start: Double, end: Double, duration: Double)]) -> Data {
            var data = Data()
            for span in spans {
                for value in [span.start, span.end, span.duration] {
                    withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
                }
            }
            return data
        }

        @Test func `a warp is checked without a synth, by PlaybackTimeWarp's rules`() {
            #expect(nativeWarpSpansAreValid(spans: Data()), "the identity")
            #expect(nativeWarpSpansAreValid(spans: Self.encoded([(0, 2, 2.5), (2, 4, 3)])))
            #expect(!nativeWarpSpansAreValid(spans: Self.encoded([(0, 2, 4), (1, 3, 2)])), "overlapping")
            #expect(!nativeWarpSpansAreValid(spans: Self.encoded([(0, 2, 1000)])), "a stretch below 0.02")
            #expect(!nativeWarpSpansAreValid(spans: Self.encoded([(2, 2, 1)])), "an end not after its start")
            #expect(!nativeWarpSpansAreValid(spans: Self.encoded([(0, 2, 4)]).dropLast()), "not whole spans")
        }

        @Test func `the warp payload is big-endian doubles, as the Kotlin side writes them`() throws {
            // 1.0, 2.0, 0.5 — the bytes `PlaybackTimeWarpSpanTest` pins on the Kotlin side.
            let bytes: [UInt8] = [
                0x3F, 0xF0, 0, 0, 0, 0, 0, 0, 0x40, 0x00, 0, 0, 0, 0, 0, 0, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0,
            ]
            let spans = try #require(RecordingBridge.warpSpans(Data(bytes)))
            #expect(spans == [PlaybackTimeWarp.Span(start: 1, end: 2, duration: 0.5)])
        }

        @Test func `the notated clock follows the transport score's repeats through the warp`() {
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            defer { nativeSynthRelease(handle: synth) }
            let score = scoreTable.insert(RepeatedScoreFixture.score())
            defer { nativeReleaseScore(handle: score) }
            nativeSynthAlignmentClear(handle: synth)
            for span in RepeatedScoreFixture.spans {
                nativeSynthAlignmentAddSpan(handle: synth, start: span.start, end: span.end, duration: span.duration)
            }
            #expect(nativeSynthAlignmentCommit(handle: synth) == 0)

            // Before the score is named: the warp alone, transport seconds taken for notated ones.
            #expect(abs(nativeSynthNotatedSecondsAtOutput(handle: synth, seconds: 4.3) - 3.2) < 1e-9)

            nativeSynthSetTransportScore(handle: synth, scoreHandle: score)
            #expect(abs(nativeSynthNotatedSecondsAtOutput(handle: synth, seconds: 4.3) - 1.2) < 1e-9, "A's 2nd pass")
            #expect(abs(nativeSynthOutputSecondsAtNotated(handle: synth, seconds: 3.0) - 6.5) < 1e-9)
            #expect(abs(nativeSynthOutputSecondsAtNotated(handle: synth, seconds: 1.2) - 1.5) < 1e-9, "1st pass")

            // An unknown score lays nothing over the transport; an unknown synth answers what it was given.
            nativeSynthSetTransportScore(handle: synth, scoreHandle: 0)
            #expect(abs(nativeSynthNotatedSecondsAtOutput(handle: synth, seconds: 4.3) - 3.2) < 1e-9)
            #expect(nativeSynthNotatedSecondsAtOutput(handle: 0, seconds: 4.3) == 4.3)
            #expect(nativeSynthOutputSecondsAtNotated(handle: 0, seconds: 4.3) == 4.3)
        }

        @Test func `the notated clock agrees with the tick clock of the sequence rendered from the score`() {
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            defer { nativeSynthRelease(handle: synth) }
            let score = scoreTable.insert(RepeatedScoreFixture.score())
            defer { nativeReleaseScore(handle: score) }
            let sequence = nativeSequenceCreate(synthHandle: synth, smf: nativeRenderMidi(scoreHandle: score))
            #expect(sequence != 0)
            defer { nativeSequenceRelease(handle: sequence) }
            nativeSynthAlignmentClear(handle: synth)
            for span in RepeatedScoreFixture.spans {
                nativeSynthAlignmentAddSpan(handle: synth, start: span.start, end: span.end, duration: span.duration)
            }
            #expect(nativeSynthAlignmentCommit(handle: synth) == 0)
            nativeSynthSetTransportScore(handle: synth, scoreHandle: score)

            // B's third quarter: notated tick 2880, played after both passes of A at unrolled tick 3840 + 960. What
            // the engine reports there (a seek, the readout) is what the notated clock converts to and from.
            let unrolled = nativeUnrolledTickForNotated(scoreHandle: score, notatedTick: 2880)
            #expect(unrolled == 4800)
            let reported = nativeSynthOutputSecondsAtTick(handle: synth, tick: unrolled)
            #expect(abs(reported - 6.5) < 1e-6)
            #expect(abs(nativeSynthOutputSecondsAtNotated(handle: synth, seconds: 3.0) - reported) < 1e-6)
            #expect(abs(nativeSynthNotatedSecondsAtOutput(handle: synth, seconds: reported) - 3.0) < 1e-6)
            #expect(nativeSynthTickAtOutputSeconds(handle: synth, seconds: reported) == 4800)
        }
    }
#endif
