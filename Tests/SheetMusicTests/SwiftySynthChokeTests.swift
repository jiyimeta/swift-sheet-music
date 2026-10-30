#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        @testable import SheetMusicCore
        import SheetMusicMIDI
        import Testing

        /// GeneralUser GS: the path the other SwiftySynth suites read, else the folino checkout's copy beside this one.
        /// The choke needs only a font with a crash cymbal, not their score.
        private let chokeSoundfontPath: String? = [
            swiftySynthSoundfontPath,
            NSString(
                string: "~/Developer/Personal/ios-apps/folino-ios/App/Resources/Soundfonts/GeneralUser-GS.sf2",
            ).expandingTildeInPath,
        ].first { FileManager.default.fileExists(atPath: $0) }

        /// The choke marker reaches the synthesizer: `SwiftySynthBackend` turns `ChokeMarker.controller` into
        /// `Synthesizer.choke(key:on:)`, so a choked crash falls silent at its written end instead of ringing on.
        /// Rendered offline at 44.1 kHz through the backend, measured as the peak of the 10 ms ending at a time.
        extension AudioEngineSerial {
            @MainActor
            struct SwiftySynthChokeTests {
                private static let sampleRate = 44100.0
                /// 10 ms.
                private static let sliceFrames: AVAudioFrameCount = 441
                /// −50 dBFS and −40 dBFS as linear peaks. GeneralUser GS's crash at the default mf still peaks near
                /// −33 dBFS 0.1 s after a quarter's end (measured 2026-10-30), so "ringing" sits 7 dB under that.
                private static let silent: Float = 0.003_162
                private static let ringing: Float = 0.01

                private func awaitReady(_ backend: SwiftySynthBackend) async throws {
                    for _ in 0 ..< 250 {
                        if backend.isReady { return }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    Issue.record("SwiftySynthBackend never became ready")
                }

                /// A crash quarter at 120 bpm (it ends at 0.5 s), choked or not, loaded into a started offline rig.
                private func makeRig(
                    choked: Bool,
                ) async throws -> (SwiftySynthBackend, AVAudioEngine, AVAudioPCMBuffer) {
                    let path = try #require(chokeSoundfontPath)
                    let backend = SwiftySynthBackend(sampleRate: Self.sampleRate)
                    backend.prepare(
                        soundfontURL: URL(fileURLWithPath: path), metronomeSoundfontURL: nil, drumChannels: [],
                    )
                    try await awaitReady(backend)
                    var score = RevoiceFixtures.score([["C/4 r/4 r/2"]])
                    if choked {
                        score = RevoiceFixtures.editingChord(score, measure: 0, voice: 0, element: 1) {
                            $0.articulations = [ChordArticulation(kind: .chokeCymbal)]
                        }
                    }
                    try backend.loadSequence(
                        MidiRenderer.renderForPlayback(score: score), timeline: PlaybackTimeline(score: score),
                    )
                    let engine = AVAudioEngine()
                    guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)
                    else { throw AVError(.unknown) }
                    engine.attach(backend.sourceNode)
                    engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
                    try engine.start()
                    let buffer = try #require(AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.sliceFrames,
                    ))
                    return (backend, engine, buffer)
                }

                /// Renders `seconds` in 10 ms slices and answers the peak of the last one.
                private func peakOfLastSlice(
                    _ engine: AVAudioEngine, _ buffer: AVAudioPCMBuffer, seconds: Double,
                ) throws -> Float {
                    let slices = Int((seconds * Self.sampleRate / Double(Self.sliceFrames)).rounded())
                    var peak: Float = 0
                    for slice in 0 ..< slices {
                        _ = try engine.renderOffline(Self.sliceFrames, to: buffer)
                        guard slice == slices - 1, let channels = buffer.floatChannelData else { continue }
                        for frame in 0 ..< Int(buffer.frameLength) {
                            peak = max(peak, abs(channels[0][frame]), abs(channels[1][frame]))
                        }
                    }
                    return peak
                }

                @Test(.enabled(if: chokeSoundfontPath != nil))
                func `a choked crash is silent 0.1 s after its written end`() async throws {
                    let (backend, engine, buffer) = try await makeRig(choked: true)
                    backend.play()
                    let peak = try peakOfLastSlice(engine, buffer, seconds: 0.6)
                    engine.stop()
                    #expect(peak < Self.silent, "peak \(peak) at 0.6 s")
                }

                @Test(.enabled(if: chokeSoundfontPath != nil))
                func `an unchoked crash still rings 0.1 s after its written end`() async throws {
                    let (backend, engine, buffer) = try await makeRig(choked: false)
                    backend.play()
                    let peak = try peakOfLastSlice(engine, buffer, seconds: 0.6)
                    engine.stop()
                    #expect(peak > Self.ringing, "peak \(peak) at 0.6 s")
                }

                /// A seek's chase does not go through `onSend`, so a choke behind the seek point is never replayed:
                /// nothing traps, and nothing sounds.
                @Test(.enabled(if: chokeSoundfontPath != nil))
                func `seeking past a choke neither traps nor sounds`() async throws {
                    let (backend, engine, buffer) = try await makeRig(choked: true)
                    backend.seek(toTick: 576) // 0.6 s at 120 bpm
                    backend.play()
                    let peak = try peakOfLastSlice(engine, buffer, seconds: 0.1)
                    engine.stop()
                    #expect(peak < Self.silent, "peak \(peak) after the seek")
                }
            }
        }
    #endif
#endif
