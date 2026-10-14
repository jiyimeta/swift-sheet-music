#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        import SheetMusic
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicMIDI
        import SheetMusicMSCX
        import Testing

        extension AudioEngineSerial {
            /// A metronome the backend stopped rendering — muted, or turned down to zero — comes back on the beat.
            ///
            /// The render block skips a silent metronome entirely, so its transport freezes. Un-muting always reseeked
            /// it to the score's position; turning the volume back up from zero did not, so after the click had been
            /// at zero for 0.75 s every later click came 0.75 s late (owner QA, 2026-10-14).
            @Suite("SwiftySynth metronome comes back on the beat")
            @MainActor
            struct SwiftySynthMetronomeResyncTests {
                private static let sampleRate = 44100.0
                /// 10 ms render blocks, the resolution clicks are timed at.
                private static let block: AVAudioFrameCount = 441
                private static let gmSoundfont = URL(fileURLWithPath: swiftySynthSoundfontPath)

                /// A click SF2 whose sample lasts 20 ms, so every click is a sharp, separate onset.
                private func writeShortClickSoundFont() throws -> URL {
                    let wave = (0 ..< 882).map { i -> Int16 in (i / 20) % 2 == 0 ? 16000 : -16000 }
                    let sf2 = ClickSoundFontBuilder.build(strong: wave, strongRate: 44100, weak: wave, weakRate: 44100)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("click-\(UUID()).sf2")
                    try sf2.write(to: url)
                    return url
                }

                private func awaitReady(_ backend: SwiftySynthBackend) async throws {
                    for _ in 0 ..< 250 {
                        if backend.isReady { return }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    Issue.record("SwiftySynthBackend never became ready")
                }

                /// Plays a click on every beat at 120 bpm — one every 0.5 s — silences the metronome from 1.0 s to
                /// 1.75 s with `silence` / `restore`, and returns the times (s) of the clicks heard from 1.8 s to
                /// 3.3 s.
                private func clickTimesAfterSilence(
                    silence: (SwiftySynthBackend) -> Void,
                    restore: (SwiftySynthBackend) -> Void,
                ) async throws -> [Double] {
                    let click = try writeShortClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: click) }
                    let backend = SwiftySynthBackend(sampleRate: Self.sampleRate)
                    backend.prepare(soundfontURL: Self.gmSoundfont, metronomeSoundfontURL: click, drumChannels: [])
                    try await awaitReady(backend)

                    // A silent score that lasts 8 s, so its transport — the position a reseek reads — keeps running.
                    let score = SheetMusicMIDI.MidiFile(division: 480, tracks: [MidiTrack(events: [
                        TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
                        TimedMidiEvent(tick: 480 * 16, event: .endOfTrack),
                    ])])
                    let scoreURL = try #require(TestResources.url(forResource: "midi01", withExtension: "mscx"))
                    let timeline = try PlaybackTimeline(score: MSCXParser.parse(contentsOf: scoreURL))
                    backend.loadSequence(score, timeline: timeline)
                    backend.loadMetronomeSequence(PreRollSequenceAssembler.metronomeOnly(
                        rendered: score,
                        metronomeBeats: (0 ..< 16).map { MetronomeBeat(tick: $0 * 480, isDownbeat: $0 % 4 == 0) },
                    ))
                    backend.setMetronomeMuted(false)
                    backend.setMetronomeVolume(1)

                    let engine = AVAudioEngine()
                    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2))
                    engine.attach(backend.sourceNode)
                    engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.block)
                    try engine.start()
                    defer {
                        engine.stop()
                        engine.disableManualRenderingMode()
                    }
                    backend.play()

                    let buffer = try #require(AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.block,
                    ))
                    var peaks: [Float] = []
                    for index in 0 ..< 330 { // 330 x 10 ms = 3.3 s
                        if index == 100 { silence(backend) }
                        if index == 175 { restore(backend) }
                        var peak: Float = 0
                        let status = try engine.renderOffline(Self.block, to: buffer)
                        if status == .success, let ch = buffer.floatChannelData {
                            for i in 0 ..< Int(buffer.frameLength) {
                                peak = max(peak, abs(ch[0][i]))
                            }
                        }
                        peaks.append(peak)
                    }
                    // An onset is a loud block after a quiet one.
                    return (180 ..< peaks.count).compactMap { index in
                        peaks[index] > 0.01 && peaks[index - 1] < 0.002 ? Double(index) * 0.01 : nil
                    }
                }

                private func expectOnTheBeat(_ times: [Double]) {
                    let message = "clicks after the silence should fall on the 0.5 s grid, at 2.0 / 2.5 / 3.0 s: "
                        + "\(times)"
                    #expect(times.count == 3, Comment(rawValue: message))
                    for (time, beat) in zip(times, [2.0, 2.5, 3.0]) {
                        #expect(abs(time - beat) <= 0.02, Comment(rawValue: message))
                    }
                }

                @Test(
                    "a metronome turned down to zero and back up stays on the beat",
                    .enabled(if: swiftySynthGMSoundfontAvailable),
                )
                func zeroVolumeKeepsTheBeat() async throws {
                    let times = try await clickTimesAfterSilence(
                        silence: { $0.setMetronomeVolume(0) },
                        restore: { $0.setMetronomeVolume(1) },
                    )
                    expectOnTheBeat(times)
                }

                @Test(
                    "a muted metronome un-muted stays on the beat",
                    .enabled(if: swiftySynthGMSoundfontAvailable),
                )
                func muteKeepsTheBeat() async throws {
                    let times = try await clickTimesAfterSilence(
                        silence: { $0.setMetronomeMuted(true) },
                        restore: { $0.setMetronomeMuted(false) },
                    )
                    expectOnTheBeat(times)
                }

                @Test(
                    "un-muting at zero volume waits for the volume before it comes back on the beat",
                    .enabled(if: swiftySynthGMSoundfontAvailable),
                )
                func unmuteAtZeroThenVolumeKeepsTheBeat() async throws {
                    let times = try await clickTimesAfterSilence(
                        silence: { backend in
                            backend.setMetronomeMuted(true)
                            backend.setMetronomeVolume(0)
                        },
                        restore: { backend in
                            backend.setMetronomeMuted(false)
                            backend.setMetronomeVolume(1)
                        },
                    )
                    expectOnTheBeat(times)
                }
            }
        }
    #endif
#endif
