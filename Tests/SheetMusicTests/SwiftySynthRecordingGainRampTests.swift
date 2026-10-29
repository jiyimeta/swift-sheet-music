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
