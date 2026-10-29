#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import Testing

        extension AudioEngineSerial {
            /// When `SwiftySynthBackend` reads recordings through its `RecordingStretcher` and how, against
            /// `FakeStretcher`, which plays its input back at the speed it is fed after its declared latency. The sound
            /// of the real stretcher is `SignalsmithStretcherTests`'.
            @Suite("Recordings through a stretcher")
            @MainActor
            struct RecordingStretcherRenderTests {
                typealias Fixtures = SwiftySynthRecordingRenderTests
                static let sampleRate = Fixtures.sampleRate
                static let fadeFrames = Fixtures.fadeFrames
                /// 70 % as the stretcher sees it: `setRate` takes a `Float`.
                static let rate70 = Double(Float(0.7))

                @Test("at 100 % and no transposition no stretcher is made or called")
                func unitRateReadsDirectly() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await Self.rig(recorder.factory)
                    defer { rig.finish() }
                    try Self.playTone(on: rig.backend)
                    let samples = try rig.render(seconds: 1)

                    #expect(recorder.made.isEmpty)
                    let deviation = Self.deviationFromTone(samples, rate: 1)
                    #expect(deviation < 1e-5, "largest deviation from the recording: \(deviation)")
                }

                @Test("at 70 % the stretcher is fed 0.7 input frames per output frame, far enough ahead to be on time")
                func feedsAheadAtRate() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await Self.rig(recorder.factory)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    try Self.playTone(on: rig.backend)
                    let samples = try rig.render(seconds: 1.5)

                    try #require(recorder.made.count == 2, "one pair")
                    let input = recorder.made.map(\.processedInput).reduce(0, +)
                    let output = recorder.made.map(\.processedOutput).reduce(0, +)
                    let ratio = Double(input) / Double(max(1, output))
                    #expect(output == samples.count, "every output frame came from the stretcher")
                    #expect(abs(ratio - 0.7) < 1e-3, "input per output frame: \(ratio)")
                    // The first stream starts on the second instance, from a seek of the length it asks for.
                    let seekLength = recorder.made[1].seekLength(rate: Self.rate70)
                    #expect(recorder.made[1].seeks == [.seek(frames: seekLength, rate: Self.rate70)])
                    // Fed `inputLatency + outputLatency × 0.7` ahead, the fake's output is the recording at the
                    // transport's position; leaving out `outputLatency × 0.7` alone would put it 140 frames late, a
                    // deviation near the tone's full 0.5. Each call is fed whole frames, so the fake's straight line
                    // through a call lands up to half a frame off: 0.5 × 0.0157 (the tone's steepest step per frame).
                    let deviation = Self.deviationFromTone(samples, rate: 0.7)
                    #expect(deviation < 0.01, "largest deviation from the recording at 70 %: \(deviation)")
                }

                @Test("a seek primes the idle instance at the new position and crossfades to it")
                func seekCrossfadesBetweenThePair() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await Self.rig(recorder.factory)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    // 0.6 for the first second, 0.2 after it.
                    let steps = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { $0 < 44100 ? 19661 : 6554 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "steps", recording: steps)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    rig.backend.play()

                    // 1.5 s at 70 % reaches 1.05 s of the recording.
                    let before = try rig.render(seconds: 1.5)
                    rig.backend.seek(toTick: 0)
                    let after = try rig.render(seconds: 0.05)

                    let fade = Self.fadeFrames
                    let ramp = "around the seek: \(before.last ?? 0) | \(after[0]), \(after[fade / 2]), \(after[300])"
                    #expect(abs((before.last ?? 0) - 0.2) < 0.01, Comment(rawValue: ramp))
                    #expect(abs(after[0] - 0.2) < 0.01, Comment(rawValue: ramp))
                    #expect(abs(after[fade / 2] - 0.4) < 0.03, Comment(rawValue: ramp))
                    #expect(abs(after[300] - 0.6) < 0.01, Comment(rawValue: ramp))
                    #expect((after[0 ..< 300].min() ?? 0) > 0.18, Comment(rawValue: ramp))
                    try #require(recorder.made.count == 2)
                    // The first instance was idle while the second played: it is the one reset, retuned and seeked.
                    let seekLength = recorder.made[0].seekLength(rate: Self.rate70)
                    #expect(Array(recorder.made[0].calls.prefix(3)) == [
                        .reset, .transpose(0), .seek(frames: seekLength, rate: Self.rate70),
                    ])
                    #expect(recorder.made[1].seeks.count == 1, "the playing instance is not seeked again")
                }

                @Test("a backend built without a factory reads recordings directly at any rate")
                func noFactoryReadsDirectly() async throws {
                    let rig = try await Self.rig(nil)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    try Self.playTone(on: rig.backend)
                    let samples = try rig.render(seconds: 1)

                    let deviation = Self.deviationFromTone(samples, rate: 0.7)
                    #expect(deviation < 1e-3, "largest deviation from the recording at 70 %: \(deviation)")
                }

                @Test("a rate change while playing crossfades between direct and stretched reading")
                func rateChangeSwitchesReadingWithoutAGap() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await Self.rig(recorder.factory)
                    defer { rig.finish() }
                    let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    rig.backend.play()

                    _ = try rig.render(seconds: 0.5)
                    rig.backend.setRate(0.7)
                    let stretched = try rig.render(seconds: 0.5)
                    rig.backend.setRate(1)
                    let direct = try rig.render(seconds: 0.5)

                    try #require(recorder.made.count == 2, "the pair is made when the rate leaves 100 %")
                    #expect(recorder.made[1].seeks.count == 1)
                    let lowest = (stretched + direct).min() ?? 0
                    let highest = (stretched + direct).max() ?? 1
                    #expect(lowest > 0.49 && highest < 0.51, "level across both switches: \(lowest) … \(highest)")
                    // Back at 100 % the stretcher stops being fed once its fade-out is over.
                    let outputAfterReturn = recorder.made[1].processedOutput
                    _ = try rig.render(seconds: 0.2)
                    #expect(recorder.made[1].processedOutput == outputAfterReturn)
                }

                @Test("each transposition gets its own pair, and changing one while playing retunes and crossfades")
                func transpositionGroups() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await Self.rig(recorder.factory)
                    defer { rig.finish() }
                    let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 8192 }
                    rig.backend.setRecordingTracks([
                        RecordingTrackRender(id: "concert", recording: level),
                        RecordingTrackRender(id: "raised", recording: level, transposeSemitones: 2),
                    ])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    rig.backend.play()
                    let first = try rig.render(seconds: 0.3)

                    // At 100 % only the transposed track needs a stretcher.
                    try #require(recorder.made.count == 2)
                    #expect(recorder.made[1].calls.prefix(2) == [.reset, .transpose(2)])
                    rig.backend.setRecordingTracks([
                        RecordingTrackRender(id: "concert", recording: level),
                        RecordingTrackRender(id: "raised", recording: level, transposeSemitones: 3),
                    ])
                    let second = try rig.render(seconds: 0.3)

                    #expect(recorder.made.count == 2, "the group keeps its pair")
                    #expect(recorder.made[0].calls.prefix(3) == [
                        .reset, .transpose(3), .seek(frames: recorder.made[0].seekLength(rate: 1), rate: 1),
                    ])
                    let settled = Array(first[Self.fadeFrames...]) + second
                    let lowest = settled.min() ?? 0
                    let highest = settled.max() ?? 1
                    #expect(lowest > 0.49 && highest < 0.51, "both tracks, across the retune: \(lowest) … \(highest)")
                }

                // MARK: Helpers

                static func rig(_ factory: RecordingStretcherFactory?) async throws -> Fixtures.Rig {
                    let font = try Fixtures.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    return try await Fixtures.Rig.make(
                        score: Fixtures.silentScore(), font: font, stretcherFactory: factory,
                    )
                }

                /// Task 5's 220 Hz tone, 3 s of it, heard from warped second 0 on.
                static func playTone(on backend: SwiftySynthBackend) throws {
                    let tone = try Fixtures.recording(rate: 44100, frames: 44100 * 3, sample: Fixtures.tone)
                    backend.setRecordingTracks([RecordingTrackRender(id: "tone", recording: tone)])
                    backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(3))
                    backend.play()
                }

                /// The largest difference after the opening fade between `samples` and the tone read at `rate` seconds
                /// of it per second: its Int16 samples, linearly interpolated as `PCMFrames` reads them.
                static func deviationFromTone(_ samples: [Float], rate: Double) -> Float {
                    (fadeFrames ..< samples.count).map { frame in
                        let position = Double(frame) * rate
                        let index = Int(position)
                        let fraction = Float(position - Double(index))
                        let low = Float(Fixtures.tone(index)) / 32768
                        let high = Float(Fixtures.tone(index + 1)) / 32768
                        return abs(samples[frame] - (low + (high - low) * fraction))
                    }.max() ?? 1
                }
            }
        }
    #endif
#endif
