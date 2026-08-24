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

        /// The click suite only needs a General-MIDI font for the score side; it does
        /// not need the `.mscz` `swiftySynthAssetsAvailable` also requires.
        var swiftySynthGMSoundfontAvailable: Bool {
            FileManager.default.fileExists(atPath: swiftySynthSoundfontPath)
        }

        extension AudioEngineSerial {
            /// The injected backend renders the metronome on its own synth. Before
            /// this suite it always built that synth from the SCORE's SoundFont, so a
            /// host-supplied click (`MetronomeClickProvider.clickSamples`) was loaded
            /// into the AUMIDISynth `MetronomeController` — which never sounds on the
            /// backend path — and playback clicked with the GM drum kit's notes 76 /
            /// 77 (Hi / Low Wood Block) instead. Offline export, still on AUMIDISynth,
            /// used the custom click all along, so the two disagreed.
            ///
            /// "Is it our click or the GM wood block?" needs more than `peak > 0`:
            /// both are audible. The discriminator here is duration — the click SF2
            /// holds a 1.5-second full-amplitude square wave, and a GM wood block has
            /// decayed to nothing well before the 0.4 s - 0.9 s window these tests
            /// measure. `MetronomeSequenceBuilder` releases each click `division / 4`
            /// ticks in, so the tempo is pinned absurdly slow (8 s per quarter = 2 s
            /// per click) to keep that window inside the sounding note.
            @Suite("SwiftySynth metronome click SoundFont")
            @MainActor
            struct SwiftySynthMetronomeClickTests {
                private static let sampleRate = 44100.0
                private static let gmSoundfont = URL(fileURLWithPath: swiftySynthSoundfontPath)

                /// A click SF2 whose samples last 1.5 s — long enough that its presence
                /// at ~0.5 s is unambiguous evidence the custom click is playing.
                private func writeLongClickSoundFont() throws -> URL {
                    let wave = (0 ..< 66150).map { i -> Int16 in
                        (i / 100) % 2 == 0 ? 16000 : -16000
                    }
                    let sf2 = ClickSoundFontBuilder.build(
                        strong: wave, strongRate: 44100, weak: wave, weakRate: 44100,
                    )
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("click-\(UUID().uuidString).sf2")
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

                /// Render one downbeat click through the backend and return the peak
                /// amplitude per 100 ms of the first 1.5 s.
                private func clickEnvelope(
                    metronomeSoundfontURL: URL?, volume: Float? = nil,
                ) async throws -> [Float] {
                    let backend = SwiftySynthBackend(sampleRate: Self.sampleRate)
                    backend.prepare(
                        soundfontURL: Self.gmSoundfont,
                        metronomeSoundfontURL: metronomeSoundfontURL,
                        drumChannels: [],
                    )
                    try await awaitReady(backend)

                    // Silent score (a lone tempo event) so only the click sounds, and
                    // slow enough that the click's note-off (division / 4 = 120 ticks)
                    // lands 2 s in — past the whole 1.5 s sample.
                    let tempoOnly = SheetMusicMIDI.MidiFile(division: 480, tracks: [
                        MidiTrack(events: [TimedMidiEvent(
                            tick: 0,
                            event: .meta(.tempo(microsecondsPerQuarter: 8_000_000)),
                        )]),
                    ])
                    let scoreURL = try #require(
                        TestResources.url(forResource: "midi01", withExtension: "mscx"),
                    )
                    let score = try MSCXParser.parse(contentsOf: scoreURL)
                    backend.loadSequence(tempoOnly, timeline: PlaybackTimeline(score: score))
                    backend.loadMetronomeSequence(
                        PreRollSequenceAssembler.metronomeOnly(
                            rendered: tempoOnly,
                            metronomeBeats: [MetronomeBeat(tick: 0, isDownbeat: true)],
                        ),
                    )
                    backend.setMetronomeMuted(false)
                    if let volume { backend.setMetronomeVolume(volume) }

                    let engine = AVAudioEngine()
                    let format = try #require(AVAudioFormat(
                        standardFormatWithSampleRate: Self.sampleRate, channels: 2,
                    ))
                    engine.attach(backend.sourceNode)
                    engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(
                        .offline, format: format, maximumFrameCount: 4410,
                    )
                    try engine.start()
                    backend.play()

                    let buffer = try #require(AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: 4410,
                    ))
                    var envelope: [Float] = []
                    for _ in 0 ..< 15 { // 15 x 100 ms = 1.5 s
                        var peak: Float = 0
                        let status = try engine.renderOffline(4410, to: buffer)
                        if status == .success, let ch = buffer.floatChannelData {
                            for i in 0 ..< Int(buffer.frameLength) {
                                peak = max(peak, abs(ch[0][i]))
                            }
                        }
                        envelope.append(peak)
                    }
                    engine.stop()
                    engine.disableManualRenderingMode()
                    return envelope
                }

                /// Quietest 100 ms across 0.4 s - 0.9 s: non-zero only if something is
                /// sounding throughout, long after a wood block would be gone.
                private func sustain(_ envelope: [Float]) -> Float {
                    envelope[4 ... 9].min() ?? 0
                }

                /// Loudest 100 ms across the same window — zero once a click has died.
                private func residue(_ envelope: [Float]) -> Float {
                    envelope[4 ... 9].max() ?? 0
                }

                @Test(
                    "host click SoundFont drives the backend metronome",
                    .enabled(if: swiftySynthGMSoundfontAvailable),
                )
                func customClickSoundsOnTheBackend() async throws {
                    let click = try writeLongClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: click) }
                    let envelope = try await clickEnvelope(metronomeSoundfontURL: click)
                    let message = "the 1.5 s click sample should still be sounding at 0.4-0.9 s; "
                        + "silence there means the GM wood block played instead: \(envelope)"
                    #expect(sustain(envelope) > 0.001, Comment(rawValue: message))
                }

                /// The metronome's mixer volume reaches the backend's own click mix.
                /// It used to stop at the AUMIDISynth `MetronomeController`, so on the
                /// backend path the click always mixed at unity: the mixer's metronome
                /// strip could mute the click but not make it quieter, while offline
                /// export (AUMIDISynth) obeyed the same slider.
                @Test(
                    "the metronome's volume scales the backend's click",
                    .enabled(if: swiftySynthGMSoundfontAvailable),
                )
                func metronomeVolumeScalesTheClick() async throws {
                    let click = try writeLongClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: click) }
                    let full = try await clickEnvelope(metronomeSoundfontURL: click, volume: 1)
                    let quiet = try await clickEnvelope(metronomeSoundfontURL: click, volume: 0.25)
                    let message = "full: \(full[2]), quarter volume: \(quiet[2])"
                    #expect(full[2] > 0.001, Comment(rawValue: message))
                    // The click is a square wave, so a gain of 0.25 is 0.25 of the peak.
                    #expect(abs(quiet[2] - full[2] * 0.25) < full[2] * 0.05, Comment(rawValue: message))
                }

                /// No host click (`.defaultGM`): the metronome shares the score's
                /// SoundFont and clicks with the GM wood block, as before — audible at
                /// the attack, and gone by 0.4 s. That decay is what makes the test
                /// above a real discriminator rather than another `peak > 0`, so it is
                /// asserted here rather than left implicit.
                @Test(
                    "no click SoundFont keeps the GM wood block",
                    .enabled(if: swiftySynthGMSoundfontAvailable),
                )
                func gmFallbackStillClicks() async throws {
                    let envelope = try await clickEnvelope(metronomeSoundfontURL: nil)
                    let message = "the GM click should sound and then decay: \(envelope)"
                    #expect(envelope[0] > 0.001, Comment(rawValue: message))
                    #expect(residue(envelope) < 0.001, Comment(rawValue: message))
                }
            }
        }
    #endif
#endif
