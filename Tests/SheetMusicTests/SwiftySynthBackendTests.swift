#if canImport(SwiftySynth)
    import AVFoundation
    import Foundation
    import SheetMusic
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore
    @testable import SheetMusicAudioSwiftySynth
    import SheetMusicMIDI
    import Testing

    let swiftySynthSoundfontPath =
        "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/Resources/Soundfonts/GeneralUser-GS.sf2"
    let swiftySynthShinogonoPath =
        NSString(string: "~/Downloads/shinogono.mscz").expandingTildeInPath

    var swiftySynthAssetsAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: swiftySynthSoundfontPath)
            && fm.fileExists(atPath: swiftySynthShinogonoPath)
    }

    extension AudioEngineSerial {
        @MainActor
        struct SwiftySynthBackendTests {
            private func makePrepared() throws -> (SwiftySynthBackend, AVAudioEngine) {
                let sampleRate = 44100.0
                let backend = SwiftySynthBackend(sampleRate: sampleRate)
                backend.prepare(
                    soundfontURL: URL(fileURLWithPath: swiftySynthSoundfontPath),
                    drumChannels: [],
                )
                let score = try SheetMusic.loadScore(
                    msczURL: URL(fileURLWithPath: swiftySynthShinogonoPath),
                )
                let midi = try MidiRenderer.render(score: score)
                backend.loadSequence(midi, timeline: PlaybackTimeline(score: score))

                let engine = AVAudioEngine()
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate, channels: 2,
                ) else { throw AVError(.unknown) }
                engine.attach(backend.sourceNode)
                engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                return (backend, engine)
            }

            /// Offline render: the transport advances and audio is produced.
            @Test(.enabled(if: swiftySynthAssetsAvailable))
            func offlineRenderAdvancesAndProducesAudio() throws {
                let (backend, engine) = try makePrepared()
                let format = engine.mainMixerNode.outputFormat(forBus: 0)
                try engine.enableManualRenderingMode(
                    .offline, format: format, maximumFrameCount: 4096,
                )
                try engine.start()
                backend.play()

                let buf = try #require(AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
                ))
                var nonSilent = false
                for _ in 0 ..< Int(2.0 * 44100 / 4096) {
                    _ = try engine.renderOffline(4096, to: buf)
                    if let ch = buf.floatChannelData {
                        for i in 0 ..< Int(buf.frameLength) where ch[0][i] != 0 {
                            nonSilent = true
                            break
                        }
                    }
                }
                let tick = backend.currentTick
                engine.stop()
                #expect(nonSilent)
                #expect(tick > 0)
            }

            /// Real-time engine: the source node is pulled on a dedicated render
            /// thread, where a main-actor-isolated render block would trap
            /// (EXC_BREAKPOINT). Guards that regression — must not crash.
            @Test(.enabled(if: swiftySynthAssetsAvailable))
            func playsOnRealRenderThreadWithoutIsolationTrap() async throws {
                let (backend, engine) = try makePrepared()
                try engine.start()
                backend.play()
                try await Task.sleep(for: .milliseconds(200))
                backend.pause()
                engine.stop()
            }

            /// `seek(toTick:)` repositions the transport; `currentTick` reads it
            /// back near the target (seconds↔tick rounding tolerance).
            @Test(.enabled(if: swiftySynthAssetsAvailable))
            func seekRepositionsTheTransport() throws {
                let (backend, _) = try makePrepared()
                backend.seek(toTick: 3840)
                #expect(backend.currentTick > 2000)
            }

            /// The metronome plays on its own transport, mixed into the score's
            /// output, and `setMetronomeMuted` silences it WITHOUT reloading the
            /// score SMF. A silent score (tempo only) isolates the click track:
            /// unmuted renders audibly, muted renders pure silence.
            private func peakRenderingMetronome(muted: Bool) throws -> Float {
                let sampleRate = 44100.0
                let backend = SwiftySynthBackend(sampleRate: sampleRate)
                backend.prepare(
                    soundfontURL: URL(fileURLWithPath: swiftySynthSoundfontPath),
                    drumChannels: [],
                )
                // Silent score (a lone tempo event) so only the metronome sounds.
                let tempoOnly = SheetMusicMIDI.MidiFile(division: 480, tracks: [
                    MidiTrack(events: [TimedMidiEvent(
                        tick: 0,
                        event: .meta(.tempo(microsecondsPerQuarter: 500_000)),
                    )]),
                ])
                let score = try SheetMusic.loadScore(
                    msczURL: URL(fileURLWithPath: swiftySynthShinogonoPath),
                )
                backend.loadSequence(tempoOnly, timeline: PlaybackTimeline(score: score))
                let beats = [
                    MetronomeBeat(tick: 0, isDownbeat: true),
                    MetronomeBeat(tick: 480, isDownbeat: false),
                    MetronomeBeat(tick: 960, isDownbeat: false),
                ]
                backend.loadMetronomeSequence(
                    PreRollSequenceAssembler.metronomeOnly(
                        rendered: tempoOnly, metronomeBeats: beats,
                    ),
                )
                backend.setMetronomeMuted(muted)

                let engine = AVAudioEngine()
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate, channels: 2,
                ) else { throw AVError(.unknown) }
                engine.attach(backend.sourceNode)
                engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                try engine.enableManualRenderingMode(
                    .offline, format: format, maximumFrameCount: 4096,
                )
                try engine.start()
                backend.play()

                let buf = try #require(AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
                ))
                var peak: Float = 0
                for _ in 0 ..< Int(1.5 * sampleRate / 4096) {
                    _ = try engine.renderOffline(4096, to: buf)
                    if let ch = buf.floatChannelData {
                        for i in 0 ..< Int(buf.frameLength) {
                            peak = max(peak, abs(ch[0][i]))
                        }
                    }
                }
                engine.stop()
                return peak
            }

            @Test(.enabled(if: swiftySynthAssetsAvailable))
            func metronomeMixesInAndMutesLive() throws {
                #expect(try peakRenderingMetronome(muted: false) > 0.001)
                #expect(try peakRenderingMetronome(muted: true) == 0)
            }
        }
    }
#endif
