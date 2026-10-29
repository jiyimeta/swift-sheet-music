#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Darwin
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSignalsmith
        @testable import SheetMusicAudioSwiftySynth
        import Testing

        extension AudioEngineSerial {
            /// What Signalsmith Stretch sounds like through `SwiftySynthBackend`'s render: pitch kept at another tempo,
            /// pitch moved by a transposition, timing kept through the latency compensation, and a loop wrap without a
            /// gap. Generated recordings only, so nothing is gated. The render rules are in
            /// `RecordingStretcherRenderTests`.
            @Suite("Signalsmith Stretch through the render")
            @MainActor
            struct SignalsmithStretcherTests {
                typealias Fixtures = SwiftySynthRecordingRenderTests
                static let sampleRate = Fixtures.sampleRate

                @Test("at 70 % a 440 Hz recording stays at 440 Hz and lasts 1 / 0.7 as long")
                func rateKeepsPitch() async throws {
                    let rig = try await Self.rig()
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    // 3 s of tone, of which the segment plays 2 s: the reading past its end is still the tone, so the
                    // end heard is the fade-out at the segment's end, not the file running out.
                    let tone = try Self.tone(hertz: 440, seconds: 3)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "tone", recording: tone)])
                    rig.backend.setPlaybackAlignment(
                        warp: nil, segments: [RecordingSegment(sourceStart: 0, sourceEnd: 2, outputStart: 0)],
                    )
                    rig.backend.play()
                    let samples = try rig.render(seconds: 3.2)

                    let middle = samples[Self.frame(1) ..< Self.frame(1.5)]
                    let pitch = Self.peakFrequency(middle, around: 440)
                    #expect(abs(pitch - 440) <= 2, "pitch at 70 %: \(pitch) Hz")
                    let sounding = try #require(Self.soundingSpan(samples))
                    let seconds = Double(sounding.count) / Self.sampleRate
                    #expect(abs(seconds - 2 / 0.7) < 0.01, "2 s of the recording lasted \(seconds) s at 70 %")
                }

                @Test("+2 semitones moves a 440 Hz recording to 493.9 Hz")
                func transpositionMovesPitch() async throws {
                    let rig = try await Self.rig()
                    defer { rig.finish() }
                    let tone = try Self.tone(hertz: 440, seconds: 2)
                    rig.backend.setRecordingTracks([
                        RecordingTrackRender(id: "tone", recording: tone, transposeSemitones: 2),
                    ])
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(2))
                    rig.backend.play()
                    let samples = try rig.render(seconds: 1.5)

                    let pitch = Self.peakFrequency(samples[Self.frame(0.5) ..< Self.frame(1)], around: 493.9)
                    #expect(abs(pitch - 493.88) <= 3, "pitch at +2 semitones: \(pitch) Hz")
                }

                /// The recording's impulses sit on the warped beats; at 70 % each is heard at its warped second / 0.7.
                /// The warp exercises the render's span boundaries with the stretcher in place.
                @Test("at 70 % the recording's impulses land on the warped beats within 1 ms")
                func impulsesLandOnTheWarpedBeats() async throws {
                    let rig = try await Self.rig()
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    // Transport 1 s – 2 s lasts 1.25 s, so the beats at transport 0.5, 1, 1.6 and 2 s are at warped
                    // seconds 0.5, 1, 1.75 and 2.25.
                    let warp = try PlaybackTimeWarp(spans: [.init(start: 1, end: 2, duration: 1.25)])
                    let beats = [0.5, 1.0, 1.75, 2.25]
                    let recording = try Fixtures.impulses(at: beats, rate: 44100, length: 3)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "beats", recording: recording)])
                    rig.backend.setPlaybackAlignment(warp: warp, segments: Fixtures.wholeRecording(3))
                    rig.backend.play()
                    let samples = try rig.render(seconds: 3.5)

                    for beat in beats {
                        let expected = Self.frame(beat / 0.7)
                        let window = (expected - Self.frame(0.05)) ..< (expected + Self.frame(0.05))
                        let peak = window.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
                        let offset = Double(peak - expected) / Self.sampleRate * 1000
                        #expect(abs(offset) <= 1, "impulse for the beat at \(beat) s heard \(offset) ms off")
                    }
                }

                /// The loop starts 1 s into the recording, as a loop start usually sits mid-performance. A wrap onto a
                /// recording's very first sample is an onset after digital silence instead, and there the stretcher's
                /// output peaks about 6 % over the recording some 40 ms in, as it does when playback starts there
                /// (measured 0.530 against 0.5, both places); that is the stretcher's onset, not the crossfade.
                @Test("a loop wrap at 70 % crossfades without a gap or a burst")
                func loopWrapHasNoGapOrBurst() async throws {
                    let rig = try await Self.rig()
                    defer { rig.finish() }
                    rig.backend.setRate(0.7)
                    let tone = try Self.tone(hertz: 440, seconds: 5)
                    rig.backend.setRecordingTracks([RecordingTrackRender(id: "tone", recording: tone)])
                    rig.backend.setPlaybackAlignment(
                        warp: nil, segments: [RecordingSegment(sourceStart: 1, sourceEnd: 5, outputStart: 0)],
                    )
                    rig.backend.play()

                    // 1.53 s at 70 % reaches 1.071 s past the loop start: 471.24 cycles, so the two sides of the wrap
                    // are out of phase and a cut would show. (At 1.5 s the gap is 462 whole cycles, and a cut in place
                    // of the crossfade went unnoticed.)
                    let before = try rig.render(seconds: 1.53)
                    rig.backend.seek(toTick: 0)
                    let after = try rig.render(seconds: 0.3)

                    // From past the opening fade-in on.
                    let heard = Array(before[Self.frame(0.1)...]) + after
                    let silentRun = Fixtures.longestSilentRun(heard)
                    #expect(silentRun <= Self.frame(0.001), "longest run below 1e-4: \(silentRun) frames")
                    let sourcePeak: Float = 16384 / 32768
                    let peak = heard.map(abs).max() ?? 0
                    let peakAt = heard.firstIndex { abs($0) == peak } ?? -1
                    let steadyPeak = before[Self.frame(0.5) ..< Self.frame(1.4)].map(abs).max() ?? 0
                    let afterPeak = after.map(abs).max() ?? 0
                    let detail = "peak \(peak) at heard frame \(peakAt) (wrap at \(before.count - Self.frame(0.1))); "
                        + "steady before the wrap \(steadyPeak), after it \(afterPeak); recording \(sourcePeak)"
                    // A crossfade that summed both stretchers at full weight would reach about twice the recording.
                    #expect(peak <= sourcePeak * 1.02, Comment(rawValue: detail))
                    let wrapPeak = after.prefix(Self.frame(0.05)).map(abs).max() ?? 0
                    #expect(wrapPeak > 0.4, "the tone sounds through the wrap: peak \(wrapPeak)")
                    // The tone's own steepest step between frames is 0.5 × 2π × 440 / 44 100 ≈ 0.031; a wrap that cut
                    // from one phase to the other would step by up to the tone's whole height.
                    let steepest = zip(heard.dropFirst(), heard).map { abs($0 - $1) }.max() ?? 0
                    #expect(steepest < 0.05, "largest step between frames: \(steepest)")
                }

                /// Zone statistics count the memory in use, so this sees a buffer that grows, not a `malloc` freed
                /// within the same call; `Sources/CSignalsmithStretch/VENDORED.md` has the code reading for the
                /// second kind.
                /// Other threads of the test process allocate too, so a window disturbed by them is measured again.
                @Test("process, reset and seek leave the heap as they found it once warmed")
                func processAllocatesNothing() {
                    // Transposed, so the peak search that only a transposition runs is exercised too.
                    let stretcher = SignalsmithStretcher(sampleRate: 48000)
                    stretcher.setTransposeSemitones(2)
                    let rate = 0.7
                    let seekLength = stretcher.seekLength(rate: rate)
                    let input = UnsafeMutablePointer<Float>.allocate(capacity: seekLength)
                    let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
                    let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
                    defer {
                        input.deallocate()
                        left.deallocate()
                        right.deallocate()
                    }
                    for frame in 0 ..< seekLength {
                        (input + frame).initialize(to: Float(0.5 * sin(Double(frame) * 0.0577)))
                    }
                    func run(calls: Int) {
                        stretcher.reset()
                        stretcher.seek(left: input, right: input, frames: seekLength, rate: rate)
                        for _ in 0 ..< calls {
                            stretcher.process(
                                inputLeft: input, inputRight: input, inputFrames: 358,
                                outputLeft: left, outputRight: right, outputFrames: 512,
                            )
                        }
                    }
                    run(calls: 200)

                    var deltas: [(blocks: Int, bytes: Int)] = []
                    for _ in 0 ..< 10 {
                        let before = Self.heapInUse()
                        run(calls: 200)
                        let after = Self.heapInUse()
                        deltas.append((after.blocks - before.blocks, after.bytes - before.bytes))
                        if deltas.last.map({ $0.blocks == 0 && $0.bytes == 0 }) == true { break }
                    }
                    let clean = deltas.contains { $0.blocks == 0 && $0.bytes == 0 }
                    #expect(clean, "heap change per window (blocks, bytes): \(deltas)")
                }

                // MARK: Helpers

                static func rig() async throws -> Fixtures.Rig {
                    let font = try Fixtures.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    return try await Fixtures.Rig.make(
                        score: Fixtures.silentScore(), font: font, stretcherFactory: .signalsmith,
                    )
                }

                /// A sine at half scale, at the engine rate.
                static func tone(hertz: Double, seconds: Double) throws -> MappedRecording {
                    try Fixtures.recording(rate: 44100, frames: Int(seconds * 44100)) { frame in
                        Int16((16384 * sin(2 * Double.pi * hertz * Double(frame) / 44100)).rounded())
                    }
                }

                static func frame(_ seconds: Double) -> Int {
                    Int((seconds * sampleRate).rounded())
                }

                /// The frequency within ±20 Hz of `around` where a Goertzel filter over `samples` peaks, to 0.05 Hz.
                static func peakFrequency(_ samples: ArraySlice<Float>, around center: Double) -> Double {
                    func power(_ hertz: Double) -> Double {
                        let coefficient = 2 * cos(2 * Double.pi * hertz / sampleRate)
                        var previous = 0.0
                        var beforePrevious = 0.0
                        for sample in samples {
                            let value = Double(sample) + coefficient * previous - beforePrevious
                            beforePrevious = previous
                            previous = value
                        }
                        return previous * previous + beforePrevious * beforePrevious
                            - coefficient * previous * beforePrevious
                    }
                    let coarse = stride(from: center - 20, through: center + 20, by: 1).max { power($0) < power($1) }
                    let rough = coarse ?? center
                    return stride(from: rough - 1, through: rough + 1, by: 0.05).max { power($0) < power($1) } ?? rough
                }

                /// The frames from the first to the last whose level reaches 0.1, or nil when none does.
                static func soundingSpan(_ samples: [Float]) -> Range<Int>? {
                    guard let first = samples.firstIndex(where: { abs($0) >= 0.1 }),
                          let last = samples.lastIndex(where: { abs($0) >= 0.1 })
                    else { return nil }
                    return first ..< last + 1
                }

                /// The default malloc zones' blocks and bytes in use.
                static func heapInUse() -> (blocks: Int, bytes: Int) {
                    var statistics = malloc_statistics_t()
                    malloc_zone_statistics(nil, &statistics)
                    return (Int(statistics.blocks_in_use), Int(statistics.size_in_use))
                }
            }
        }
    #endif
#endif
