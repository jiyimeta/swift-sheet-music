#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicMIDI
        import SwiftySynth
        import Testing

        extension AudioEngineSerial {
            /// Recordings mixed inside `SwiftySynthBackend`'s render, read at the position its transport is at through
            /// the speed table that also drives the transport's speed.
            ///
            /// Every test renders offline through `AVAudioEngine` manual rendering, as the export does, and needs no
            /// asset: the score synth plays a generated click SoundFont (note 76 on channel 9), and every recording is
            /// a PCM cache file written here (`SwiftySynthRecordingRenderTests+Fixtures.swift`).
            @Suite("SwiftySynth recordings on the transport")
            @MainActor
            struct SwiftySynthRecordingRenderTests {
                static let sampleRate = 44100.0
                /// A multiple of the synthesizer's 64-frame block, so every slice starts on a block start.
                static let sliceFrames: AVAudioFrameCount = 512
                /// The playhead's crossfade, 5 ms at the engine rate (220.5 frames, rounded).
                static let fadeFrames = Int((0.005 * sampleRate).rounded())

                @Test("without a warp the recording's impulses play on the score's beats")
                func impulsesPlayOnTheBeatsWithoutAWarp() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font)
                    defer { rig.finish() }
                    // At 48 kHz against the 44.1 kHz engine, so the read is resampled.
                    let beats = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
                    let recording = try Self.impulses(at: beats, rate: 48000, length: 3.5)
                    #expect(rig.backend.canPlayRecordings)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "click", recording: recording)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Self.wholeRecording(3.5))
                    rig.backend.play()
                    let samples = try rig.render(seconds: 3.2)

                    for beat in beats {
                        let offset = Self.onsetOffset(
                            in: samples, expected: Self.frame(beat), window: 2000, threshold: 0.3,
                        )
                        let message = "impulse for the beat at \(beat) s: offset \(String(describing: offset))"
                        #expect(offset.map { abs($0) <= 64 } == true, Comment(rawValue: message))
                    }
                }

                @Test("a warp moves the synth's notes and the recording's impulses to the warped downbeats together")
                func warpMovesNotesAndImpulsesTogether() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    // Measure 2 (transport 2 s – 4 s) lasts 2.5 s, so measures 3 and 4 start at 4.5 s and 6.5 s.
                    let warp = try PlaybackTimeWarp(spans: [.init(start: 2, end: 4, duration: 2.5)])
                    let warpedDownbeats = [2.0, 4.5, 6.5]

                    // The synth: a click on each downbeat of the SMF, which stays at its notated tempo.
                    let synthRig = try await Rig.make(score: Self.clickScore(ticks: [0, 1920, 3840, 5760]), font: font)
                    synthRig.backend.setPlaybackAlignment(warp: warp, segments: [])
                    synthRig.backend.play()
                    let synth = try synthRig.render(seconds: 7)
                    synthRig.finish()

                    // The recording: the performance the warp follows, its downbeats at the warped times.
                    let recordingRig = try await Rig.make(score: Self.silentScore(), font: font)
                    let recording = try Self.impulses(at: warpedDownbeats, rate: 44100, length: 8)
                    recordingRig.backend.setRecordingTracks([RecordingTrackRender(id: "take", recording: recording)])
                    recordingRig.backend.setPlaybackAlignment(warp: warp, segments: Self.wholeRecording(8))
                    recordingRig.backend.play()
                    let heard = try recordingRig.render(seconds: 7)
                    recordingRig.finish()

                    for downbeat in warpedDownbeats {
                        let expected = Self.frame(downbeat)
                        // ±0.2 s keeps the unwarped 4 s and 6 s outside the windows around 4.5 s and 6.5 s.
                        let note = Self.onsetOffset(in: synth, expected: expected, window: 8820, threshold: 0.05)
                        let impulse = Self.onsetOffset(in: heard, expected: expected, window: 8820, threshold: 0.3)
                        let message = "downbeat at \(downbeat) s: synth note \(String(describing: note)), "
                            + "impulse \(String(describing: impulse)) frames"
                        // SwiftySynth dispatches a note at the first 64-frame block start at or after its time, so a
                        // note sounds up to a block late on any transport (+56 frames on the unwarped first
                        // downbeat); the recording is read per frame.
                        #expect(note.map { $0 >= -32 && $0 <= 64 + 32 } == true, Comment(rawValue: message))
                        #expect(impulse.map { abs($0) <= 32 } == true, Comment(rawValue: message))
                    }
                }

                @Test("a warp swapped mid-render takes effect from the next block, and the recording keeps sounding")
                func warpSwapAppliesFromTheNextBlockWithoutDropout() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font)
                    defer { rig.finish() }
                    let tone = try Self.recording(rate: 44100, frames: 44100 * 6, sample: Self.tone)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "tone", recording: tone)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Self.wholeRecording(6))
                    rig.backend.play()

                    let slice = Int(Self.sliceFrames)
                    var samples = try rig.render(frames: slice * 85)
                    let beforeStart = rig.backend.currentPositionSeconds
                    samples += try rig.render(frames: slice)
                    let unwarpedStep = rig.backend.currentPositionSeconds - beforeStart

                    // Every transport second from 0 to 100 now lasts 1.25 s: the transport runs at 0.8.
                    let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 100, duration: 125)])
                    rig.backend.setPlaybackAlignment(warp: warp, segments: Self.wholeRecording(6))
                    let afterStart = rig.backend.currentPositionSeconds
                    samples += try rig.render(frames: slice)
                    let warpedStep = rig.backend.currentPositionSeconds - afterStart
                    samples += try rig.render(seconds: 1)

                    #expect(abs(unwarpedStep - Double(slice) / Self.sampleRate) < 1e-9)
                    let message = "the first slice after the swap moved the transport \(warpedStep) s"
                    #expect(abs(warpedStep - Double(slice) * 0.8 / Self.sampleRate) < 1e-9, Comment(rawValue: message))
                    let silentRun = Self.longestSilentRun(samples)
                    #expect(silentRun <= Self.frame(0.001), "longest run below 1e-4: \(silentRun) frames")
                    let tail = samples.suffix(Self.frame(0.5)).map(abs).max() ?? 0
                    #expect(tail > 0.45, "the tone after the swap peaks at \(tail)")
                }

                @Test("a pause then play fades the recording in")
                func pauseThenPlayFadesIn() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font)
                    defer { rig.finish() }
                    let level = try Self.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Self.wholeRecording(4))
                    rig.backend.play()

                    let playing = try rig.render(seconds: 0.5)
                    rig.backend.pause()
                    let paused = try rig.render(seconds: 0.1)
                    rig.backend.play()
                    let resumed = try rig.render(seconds: 0.05)

                    #expect(abs((playing.last ?? 0) - 0.5) < 0.01, "playing at \(playing.last ?? 0)")
                    #expect((paused.map(abs).max() ?? 1) < 1e-6, "a paused recording is silent")
                    let ramp = "after play: \(resumed[0]), \(resumed[Self.fadeFrames / 2]), \(resumed[400])"
                    #expect(abs(resumed[0]) < 0.01, Comment(rawValue: ramp))
                    #expect(abs(resumed[Self.fadeFrames / 2] - 0.25) < 0.03, Comment(rawValue: ramp))
                    #expect(abs(resumed[400] - 0.5) < 0.01, Comment(rawValue: ramp))
                }

                @Test("a seek crossfades the recording from where it was to where the transport went")
                func seekCrossfades() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font)
                    defer { rig.finish() }
                    // 0.6 for the first second, 0.2 after it.
                    let steps = try Self.recording(rate: 44100, frames: 44100 * 4) { $0 < 44100 ? 19661 : 6554 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "steps", recording: steps)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Self.wholeRecording(4))
                    rig.backend.play()

                    let before = try rig.render(seconds: 1.5)
                    // A loop wrap: back to the top while playing.
                    rig.backend.seek(toTick: 0)
                    let after = try rig.render(seconds: 0.05)

                    let fade = Self.fadeFrames
                    let ramp = "around the seek: \(before.last ?? 0) | \(after[0]), \(after[fade / 2]), \(after[300])"
                    #expect(abs((before.last ?? 0) - 0.2) < 0.01, Comment(rawValue: ramp))
                    // From the old position's 0.2 to the new one's 0.6, never through silence.
                    #expect(abs(after[0] - 0.2) < 0.01, Comment(rawValue: ramp))
                    #expect(abs(after[fade / 2] - 0.4) < 0.03, Comment(rawValue: ramp))
                    #expect(abs(after[300] - 0.6) < 0.01, Comment(rawValue: ramp))
                    #expect((after[0 ..< 300].min() ?? 0) > 0.18, Comment(rawValue: ramp))
                }

                /// Render calls of 500 frames end mid-block, where `MidiFileSequencer.position` already reads the
                /// block's end: a read position taken from it unadjusted would jump at every call, and the playhead
                /// would crossfade each time.
                @Test("a recording reads continuously through render calls that end mid-block")
                func recordingIsContinuousAcrossMidBlockCalls() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font, slice: 500)
                    defer { rig.finish() }
                    let recording = try Self.recording(rate: 44100, frames: 44100 * 3, sample: Self.tone)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "tone", recording: recording)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Self.wholeRecording(3))
                    rig.backend.play()
                    let samples = try rig.render(seconds: 2)

                    // After the opening fade-in, every frame is the recording's own sample at that frame.
                    let deviation = (Self.fadeFrames ..< samples.count)
                        .map { abs(samples[$0] - Float(Self.tone($0)) / 32768) }.max() ?? 1
                    #expect(deviation < 1e-5, "largest deviation from the recording: \(deviation)")
                }

                @Test("under a warp the count-in lasts its seconds at the speed of the measure it counts into")
                func countInFollowsTheWarpedMeasure() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font)
                    defer { rig.finish() }
                    let level = try Self.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    // Measure 1 lasts 2.5 s: the transport runs at 0.8, so a 1 s count lasts 1.25 s.
                    let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 2.5)])
                    rig.backend.setPlaybackAlignment(warp: warp, segments: Self.wholeRecording(4))
                    rig.backend.play(afterCountInSeconds: 1)
                    let samples = try rig.render(seconds: 1.5)

                    let bodyStart = Self.frame(1.25)
                    let around = "around the body's start: \(samples[bodyStart - 1]) | \(samples[bodyStart + 400])"
                    #expect(samples[..<bodyStart].allSatisfy { $0 == 0 }, Comment(rawValue: around))
                    #expect(abs(samples[bodyStart + 400] - 0.5) < 0.01, Comment(rawValue: around))
                }

                /// The click counts at the user's rate, so the score has to be held for as long as the count takes at
                /// that rate: at 70 % a 1 s count lasts 1 / 0.7 s. Held for the count's 1 s at 100 %, the body came in
                /// during the count, and the click then ran 0.3 s of its own clock behind the music.
                @Test("without a warp the count-in lasts its seconds at the user's rate")
                func countInWithoutAWarpFollowsTheRate() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Rig.make(score: Self.silentScore(), font: font)
                    defer { rig.finish() }
                    let level = try Self.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "level", recording: level)])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Self.wholeRecording(4))
                    rig.backend.setRate(0.7)
                    rig.backend.play(afterCountInSeconds: 1)
                    let samples = try rig.render(seconds: 2)

                    // `setRate` takes a `Float`, so the count lasts 1 ÷ Float(0.7) seconds.
                    let bodyStart = Self.frame(1 / Double(Float(0.7)))
                    let around = "around the body's start: \(samples[bodyStart - 1]) | \(samples[bodyStart + 400])"
                    #expect(samples[..<bodyStart].allSatisfy { $0 == 0 }, Comment(rawValue: around))
                    #expect(abs(samples[bodyStart + 400] - 0.5) < 0.01, Comment(rawValue: around))
                }

                /// With no warp and no recording the render is SwiftySynth's own: the same samples a bare
                /// `MidiFileSequencer` renders from the same SMF at the same speed, in the same slices. Slices of 500
                /// frames end mid-block, so the chunked body's block bookkeeping is exercised.
                @Test("without an alignment the render is the sequencer's own, sample for sample")
                func withoutAlignmentTheRenderIsUnchanged() async throws {
                    let font = try Self.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let score = Self.clickScore(ticks: [0, 480, 960, 1200, 1920, 2400, 2880, 3360])
                    let rate: Float = 0.9
                    let slice = 500
                    let frames = Self.frame(2.5)

                    let rig = try await Rig.make(score: score, font: font, slice: AVAudioFrameCount(slice))
                    defer { rig.finish() }
                    rig.backend.setRate(rate)
                    rig.backend.setRecordingTracks([])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: [])
                    rig.backend.play()
                    let rendered = try rig.render(frames: frames)

                    let settings = try SynthesizerSettings(
                        sampleRate: Int(Self.sampleRate), maximumPolyphony: 256,
                        enableReverbAndChorus: true, enableModulators: true,
                    )
                    let synthesizer = try SwiftySynth.Synthesizer(
                        soundFont: SwiftySynth.SoundFont(url: font), settings: settings,
                    )
                    synthesizer.masterVolume = 1
                    let sequencer = MidiFileSequencer(synthesizer: synthesizer)
                    let smf = try SwiftySynth.MidiFile(data: MidiWriter.write(score))
                    sequencer.play(smf, loop: false)
                    sequencer.speed = Double(rate)
                    var left = [Float](repeating: 0, count: frames)
                    var right = [Float](repeating: 0, count: frames)
                    for start in stride(from: 0, to: frames, by: slice) {
                        let range = start ..< min(start + slice, frames)
                        left.withUnsafeMutableBufferPointer { left in
                            right.withUnsafeMutableBufferPointer { right in
                                sequencer.render(
                                    left: UnsafeMutableBufferPointer(rebasing: left[range]),
                                    right: UnsafeMutableBufferPointer(rebasing: right[range]),
                                )
                            }
                        }
                    }

                    #expect((left.map(abs).max() ?? 0) > 0.05, "the reference must sound")
                    let difference = zip(rendered, left).map { abs($0 - $1) }.max() ?? 1
                    #expect(difference == 0, "largest difference from the bare sequencer: \(difference)")
                }
            }
        }
    #endif
#endif
