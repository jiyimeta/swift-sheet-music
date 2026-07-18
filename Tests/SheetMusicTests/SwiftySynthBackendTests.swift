#if canImport(SwiftySynth)
    import AVFoundation
    import Foundation
    import SheetMusic
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
        }
    }
#endif
