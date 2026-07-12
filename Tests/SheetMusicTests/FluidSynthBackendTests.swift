#if canImport(CFluidSynth)
    import AVFoundation
    import Foundation
    import SheetMusic
    @testable import SheetMusicAudioFluidSynth
    import SheetMusicMIDI
    import Testing

    extension AudioEngineSerial {
        @MainActor
        struct FluidSynthBackendTests {
            /// Attaches the FluidSynth source node into a real (offline-rendering)
            /// `AVAudioEngine`, plays the score's SMF, and confirms the graph
            /// produces audio and the transport clock advances.
            @Test(.enabled(if: shinogonoAndSoundfontAvailable))
            func backendProducesAudioAndAdvancesTransport() throws {
                let sampleRate = 44100.0
                let backend = FluidSynthBackend(sampleRate: sampleRate)
                backend.prepare(
                    soundfontURL: URL(fileURLWithPath: generalUserGSPath),
                    drumChannels: [],
                )
                let score = try SheetMusic.loadScore(
                    msczURL: URL(fileURLWithPath: shinogonoPath),
                )
                let midi = try MidiRenderer.render(score: score)
                backend.loadSequence(midi, division: midi.division)

                let engine = AVAudioEngine()
                let format = try #require(AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate, channels: 2,
                ))
                engine.attach(backend.sourceNode)
                engine.connect(
                    backend.sourceNode, to: engine.mainMixerNode, format: format,
                )
                try engine.enableManualRenderingMode(
                    .offline, format: format, maximumFrameCount: 4096,
                )
                try engine.start()
                backend.play()

                let buf = try #require(AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
                ))
                var nonSilent = false
                let blocks = Int(2.0 * sampleRate / 4096) // ~2 s
                for _ in 0 ..< blocks {
                    _ = try engine.renderOffline(4096, to: buf)
                    if let channels = buf.floatChannelData {
                        let frames = Int(buf.frameLength)
                        for i in 0 ..< frames where channels[0][i] != 0 {
                            nonSilent = true
                            break
                        }
                    }
                }
                engine.stop()

                #expect(nonSilent)
                #expect(backend.currentTick > 0)
            }

            /// Regression guard for the `@MainActor` render-block isolation trap
            /// (EXC_BREAKPOINT on the audio render thread). Offline rendering runs
            /// the block on the caller's thread and masks it, so this drives a
            /// *real-time* engine whose dedicated render thread pulls the node —
            /// which is exactly what crashed the example app on first play.
            @Test(.enabled(if: shinogonoAndSoundfontAvailable))
            func playsOnRealRenderThreadWithoutIsolationTrap() async throws {
                let sampleRate = 44100.0
                let backend = FluidSynthBackend(sampleRate: sampleRate)
                backend.prepare(
                    soundfontURL: URL(fileURLWithPath: generalUserGSPath),
                    drumChannels: [],
                )
                let score = try SheetMusic.loadScore(
                    msczURL: URL(fileURLWithPath: shinogonoPath),
                )
                let midi = try MidiRenderer.render(score: score)
                backend.loadSequence(midi, division: midi.division)

                let engine = AVAudioEngine()
                let format = try #require(AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate, channels: 2,
                ))
                engine.attach(backend.sourceNode)
                engine.connect(
                    backend.sourceNode, to: engine.mainMixerNode, format: format,
                )
                // Real-time mode: the engine pulls the source node on its own
                // render thread, where a main-actor-isolated block would trap.
                try engine.start()
                backend.play()
                try await Task.sleep(for: .milliseconds(300))
                let tick = backend.currentTick
                backend.stop()
                engine.stop()
                #expect(tick > 0) // advanced on the render thread, no trap
            }
        }
    }
#endif
