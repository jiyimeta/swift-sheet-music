#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        import SheetMusic
        @testable import SheetMusicAudioApple
        import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicMIDI
        import Testing

        /// What a paused transport leaves inside the synthesizer, and what the next `AVAudioEngine.start()` does with
        /// it.
        ///
        /// `SwiftySynthBackend.pause()` only clears `isPlaying`, so no note-off ever reaches the voices that were
        /// sounding at that instant: they stay in their sustain segment indefinitely. That is invisible while the
        /// host also parks the engine (a paused `AVAudioEngine` renders nothing) — until something starts the graph
        /// again for a reason of its own. `PlaybackEngine.playPreview` is exactly that: it resumes a host-parked
        /// engine to sound a single note, and the held voices resume with it, under the preview.
        ///
        /// These tests render offline, so they measure the voices rather than the audio route — no hardware, no ears.
        extension AudioEngineSerial {
            @MainActor
            struct SwiftySynthPausedVoiceTests {
                private static let sampleRate = 44100.0
                private static let framesPerSlice: AVAudioFrameCount = 4096

                private func awaitReady(_ backend: SwiftySynthBackend) async throws {
                    for _ in 0 ..< 250 {
                        if backend.isReady { return }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    Issue.record("SwiftySynthBackend never became ready")
                }

                /// A backend loaded with the test score, wired into an engine already in offline manual-rendering
                /// mode and started, so every `renderSlices` call below is deterministic.
                private func makeOfflineRig() async throws -> (SwiftySynthBackend, AVAudioEngine, AVAudioPCMBuffer) {
                    let backend = SwiftySynthBackend(sampleRate: Self.sampleRate)
                    backend.prepare(
                        soundfontURL: URL(fileURLWithPath: swiftySynthSoundfontPath),
                        metronomeSoundfontURL: nil,
                        drumChannels: [],
                    )
                    try await awaitReady(backend)
                    let score = try SheetMusic.loadScore(
                        msczURL: URL(fileURLWithPath: swiftySynthShinogonoPath),
                    )
                    let midi = try MidiRenderer.render(score: score)
                    backend.loadSequence(midi, timeline: PlaybackTimeline(score: score))

                    let engine = AVAudioEngine()
                    guard let format = AVAudioFormat(
                        standardFormatWithSampleRate: Self.sampleRate, channels: 2,
                    ) else { throw AVError(.unknown) }
                    engine.attach(backend.sourceNode)
                    engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(
                        .offline, format: format, maximumFrameCount: Self.framesPerSlice,
                    )
                    try engine.start()
                    let buffer = try #require(AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.framesPerSlice,
                    ))
                    return (backend, engine, buffer)
                }

                /// Renders `seconds` of audio and answers the peak absolute sample of the LAST slice only — "is
                /// anything still sounding at the end of this window", which is what separates a release tail from a
                /// held voice.
                private func renderPeakOfFinalSlice(
                    _ engine: AVAudioEngine, into buffer: AVAudioPCMBuffer, seconds: Double,
                ) throws -> Float {
                    let slices = max(1, Int(seconds * Self.sampleRate / Double(Self.framesPerSlice)))
                    var peak: Float = 0
                    for slice in 0 ..< slices {
                        _ = try engine.renderOffline(Self.framesPerSlice, to: buffer)
                        guard slice == slices - 1, let channels = buffer.floatChannelData else { continue }
                        for frame in 0 ..< Int(buffer.frameLength) {
                            peak = max(peak, abs(channels[0][frame]))
                        }
                    }
                    return peak
                }

                /// **The bug, stated as a measurement.** Play, pause, then keep rendering: five seconds after the
                /// pause the graph must be silent, because a pause that leaves voices sustaining has nothing to end
                /// them — the next `engine.start()` (a note preview) resumes them under the preview note.
                ///
                /// Five seconds is far longer than any release tail the test font produces, so a non-zero peak here
                /// is a held voice rather than a decay in progress.
                @Test(.enabled(if: swiftySynthAssetsAvailable))
                func pauseLeavesNothingSoundingAfterTheReleaseTail() async throws {
                    let (backend, engine, buffer) = try await makeOfflineRig()
                    backend.play()
                    let whilePlaying = try renderPeakOfFinalSlice(engine, into: buffer, seconds: 2.0)
                    backend.pause()
                    let afterPause = try renderPeakOfFinalSlice(engine, into: buffer, seconds: 5.0)
                    engine.stop()

                    // The score has to be sounding at the pause, or the measurement below proves nothing.
                    #expect(whilePlaying > 0.001, "nothing was sounding at the pause point")
                    #expect(
                        afterPause < whilePlaying / 100,
                        "voices are still held 5 s after pause: playing \(whilePlaying), after pause \(afterPause)",
                    )
                }
            }
        }
    #endif
#endif
