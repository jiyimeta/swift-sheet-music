#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import Testing

        extension AudioEngineSerial {
            /// A recording's gain changing while it plays — a mute, a solo, a volume drag, all of which the engine
            /// hands over as a new gain for the same track — ramps over the 5 ms fade instead of stepping, whether the
            /// track is read directly or through its group's stretcher. The recording is a constant 0.5, so every
            /// change from one sample to the next is the gain's.
            @Suite("Recording gain ramps")
            @MainActor
            struct SwiftySynthRecordingGainRampTests {
                typealias Fixtures = SwiftySynthRecordingRenderTests
                /// What a ramp over the fade moves a constant 0.5 per frame.
                static let rampStep = 0.5 / Float(Fixtures.fadeFrames)

                @Test("a mute and an unmute while playing ramp a recording read directly")
                func muteRampsDirectReading() async throws {
                    let rig = try await RecordingStretcherRenderTests.rig(nil)
                    defer { rig.finish() }
                    let heard = try Self.muteAndUnmute(on: rig)

                    try Self.expectMutedAndBack(heard)
                    let step = Self.largestStep(heard)
                    #expect(step <= Self.rampStep + 1e-5, "largest step \(step), a ramp's is \(Self.rampStep)")
                }

                /// The stretcher's input carries the gain, so the change reaches the output one stretcher lead late,
                /// and at 70 % each output frame moves 0.7 input frames along the ramp (measured: 0.70 of a ramp
                /// step). The bound leaves room for `FakeStretcher`'s one straight line through each call's input,
                /// which can land up to half an input frame off at a call boundary.
                @Test("a mute and an unmute while playing ramp a recording read through a stretcher")
                func muteRampsStretchedReading() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await RecordingStretcherRenderTests.rig(recorder.factory)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    let heard = try Self.muteAndUnmute(on: rig)

                    #expect(recorder.made.count == 2, "read through a stretcher pair")
                    try Self.expectMutedAndBack(heard)
                    let step = Self.largestStep(heard)
                    #expect(step <= 1.5 * Self.rampStep, "largest step \(step), a ramp's is \(Self.rampStep)")
                }

                // MARK: A gain handed over while the recording is silent

                /// Nothing is heard in a gap, so the gain steps there: the stretcher is primed on its return with the
                /// gain it was handed, not with history at the old one, which would play for a stretcher lead.
                @Test("a mute in a gap is the gain a recording read through a stretcher comes back at")
                func muteInAGapHoldsWhenTheStretchedReadingReturns() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await RecordingStretcherRenderTests.rig(recorder.factory)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    // Heard for warped 0–0.5 s and again from 1 s on, a gap between.
                    rig.backend.setPlaybackAlignment(warp: nil, segments: [
                        RecordingSegment(sourceStart: 0, sourceEnd: 0.5, outputStart: 0),
                        RecordingSegment(sourceStart: 1, sourceEnd: 4, outputStart: 1),
                    ])
                    rig.backend.play()
                    // At 70 % warped 0.5 s comes 0.71 s in, and warped 1 s 1.43 s in.
                    let before = try rig.render(seconds: 0.85)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level, gain: 0)])
                    let after = try rig.render(seconds: 1)

                    #expect(recorder.made.count == 2, "read through a stretcher pair")
                    #expect((before.map(abs).max() ?? 0) > 0.45, "heard before the gap")
                    #expect((before.suffix(Fixtures.frame(0.05)).map(abs).max() ?? 1) < 1e-6, "silent in the gap")
                    let leak = after.map(abs).max() ?? 1
                    #expect(leak < 1e-6, "loudest sample after the mute, across the return: \(leak)")
                }

                /// A paused graph may be parked, so no render runs between a pause and the next play to settle the
                /// gain: the resume itself must start at the gain handed over meanwhile.
                @Test("a mute while paused is the gain a recording read through a stretcher resumes at")
                func muteWhilePausedHoldsWhenTheStretchedReadingResumes() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await RecordingStretcherRenderTests.rig(recorder.factory)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    let (before, after) = try Self.muteWhilePaused(on: rig)

                    #expect(recorder.made.count == 2, "read through a stretcher pair")
                    #expect(abs((before.last ?? 0) - 0.5) < 0.01, "heard before the pause")
                    let leak = after.map(abs).max() ?? 1
                    #expect(leak < 1e-6, "loudest sample after the resume: \(leak)")
                }

                /// Read directly, a ramp from the old gain would run against the playhead's fade-in, a bump of up to
                /// a quarter of the level.
                @Test("a mute while paused is the gain a recording read directly resumes at")
                func muteWhilePausedHoldsWhenTheDirectReadingResumes() async throws {
                    let rig = try await RecordingStretcherRenderTests.rig(nil)
                    defer { rig.finish() }
                    let (before, after) = try Self.muteWhilePaused(on: rig)

                    #expect(abs((before.last ?? 0) - 0.5) < 0.01, "heard before the pause")
                    let leak = after.map(abs).max() ?? 1
                    #expect(leak < 1e-6, "loudest sample after the resume: \(leak)")
                }

                /// A rate change back to 100 % switches a recording to direct reading, which fades in from silence
                /// while the stretcher fades out. A mute handed over with it is the gain the direct reading fades in
                /// at: only the stretcher's fade-out from the old level is heard.
                @Test("a mute handed over with a switch to direct reading is the gain that reading fades in at")
                func muteWithASwitchToDirectReadingHolds() async throws {
                    let recorder = FakeStretcherRecorder()
                    let rig = try await RecordingStretcherRenderTests.rig(recorder.factory)
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    rig.backend.play()
                    let before = try rig.render(seconds: 0.5)
                    rig.backend.setRate(1)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level, gain: 0)])
                    let after = try rig.render(seconds: 0.05)

                    #expect(abs((before.last ?? 0) - 0.5) < 0.01, "heard before the switch")
                    // The stretcher's fade-out: 0.5 falling linearly to 0 over the fade.
                    let fade = Fixtures.fadeFrames
                    let excess = after.indices.map { frame in
                        abs(after[frame]) - 0.5 * Float(max(0, fade - frame)) / Float(fade)
                    }.max() ?? 1
                    #expect(excess < 0.01, "loudest sample above the stretcher's fade-out: \(excess)")
                }

                /// A constant 0.5 played for 0.5 s, paused, handed over at gain 0 with nothing rendered meanwhile, as
                /// with the graph parked, then played for 0.5 s.
                static func muteWhilePaused(on rig: Fixtures.Rig) throws -> (before: [Float], after: [Float]) {
                    let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    rig.backend.play()
                    let before = try rig.render(seconds: 0.5)
                    rig.backend.pause()
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level, gain: 0)])
                    rig.backend.play()
                    let after = try rig.render(seconds: 0.5)
                    return (before, after)
                }

                /// What was heard: the last 0.1 s at full gain, 0.2 s after the mute, 0.2 s after the unmute.
                struct Heard {
                    let playing: [Float]
                    let muted: [Float]
                    let unmuted: [Float]
                }

                /// A constant 0.5 played for 0.5 s, then the same track handed over at gain 0, then at gain 1 again.
                static func muteAndUnmute(on rig: Fixtures.Rig) throws -> Heard {
                    let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    rig.backend.play()
                    let playing = try rig.render(seconds: 0.5)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level, gain: 0)])
                    let muted = try rig.render(seconds: 0.2)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level, gain: 1)])
                    let unmuted = try rig.render(seconds: 0.2)
                    return Heard(playing: Array(playing.suffix(Fixtures.frame(0.1))), muted: muted, unmuted: unmuted)
                }

                /// The mute and the unmute both happened, and neither started from silence: the track kept its
                /// playhead, so its level carried on from where it was.
                static func expectMutedAndBack(_ heard: Heard) throws {
                    let playing = try #require(heard.playing.last)
                    let mutedTail = heard.muted.suffix(Fixtures.frame(0.05)).map(abs).max() ?? 1
                    let unmuted = try #require(heard.unmuted.last)
                    let levels = "playing \(playing), muted tail \(mutedTail), unmuted \(unmuted)"
                    #expect(abs(playing - 0.5) < 0.01, Comment(rawValue: levels))
                    #expect(mutedTail < 1e-6, Comment(rawValue: levels))
                    #expect(abs(unmuted - 0.5) < 0.01, Comment(rawValue: levels))
                    #expect(heard.muted.first.map { $0 > 0.49 } == true, "the mute starts from the level")
                    #expect(heard.unmuted.first.map { $0 < 0.01 } == true, "the unmute starts from silence")
                }

                /// The largest change between consecutive samples across the three stretches.
                static func largestStep(_ heard: Heard) -> Float {
                    let samples = heard.playing + heard.muted + heard.unmuted
                    return zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
                }
            }
        }
    #endif
#endif
