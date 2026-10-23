#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicMIDI
        import Testing

        /// A live pitch-wheel value is only as wide as the channel's bend sensitivity. `MidiEvent.pitchBendValue`
        /// scales cents to the 12 semitones the renderer's track header sets, but a live channel nothing has played on
        /// yet is still at the GM default of 2 — so the same value bends a sixth as far, and a quarter-tone audition
        /// comes out 8 cents flat instead of 50.
        ///
        /// Rendered offline and measured by the period of what comes out, so it is the voice that is checked, not the
        /// messages.
        extension AudioEngineSerial {
            @MainActor
            struct SwiftySynthMicrotonalAuditionTests {
                private static let sampleRate = 44100.0
                private static let framesPerSlice: AVAudioFrameCount = 4096

                private nonisolated static var soundfontAvailable: Bool {
                    FileManager.default.fileExists(atPath: swiftySynthSoundfontPath)
                }

                private func awaitReady(_ backend: SwiftySynthBackend) async throws {
                    for _ in 0 ..< 250 {
                        if backend.isReady { return }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    Issue.record("SwiftySynthBackend never became ready")
                }

                /// Sounds A4 on a freshly prepared backend with the wheel at `wheel`, and answers the fundamental of
                /// what it renders between 0.1 s and 0.4 s — past the attack, before the decay thins it out.
                private func renderedFrequency(wheel: UInt16) async throws -> Double {
                    let backend = SwiftySynthBackend(sampleRate: Self.sampleRate)
                    backend.prepare(
                        soundfontURL: URL(fileURLWithPath: swiftySynthSoundfontPath),
                        metronomeSoundfontURL: nil,
                        drumChannels: [],
                    )
                    try await awaitReady(backend)

                    let engine = AVAudioEngine()
                    guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else {
                        throw AVError(.unknown)
                    }
                    engine.attach(backend.sourceNode)
                    engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(
                        .offline, format: format, maximumFrameCount: Self.framesPerSlice,
                    )
                    try engine.start()
                    defer { engine.stop() }
                    let buffer = try #require(AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.framesPerSlice,
                    ))

                    backend.sendPitchBend(channel: 0, value: wheel)
                    backend.startNote(channel: 0, pitch: 69, velocity: 100)
                    var samples: [Float] = []
                    while samples.count < Int(0.4 * Self.sampleRate) {
                        _ = try engine.renderOffline(Self.framesPerSlice, to: buffer)
                        let channels = try #require(buffer.floatChannelData)
                        let rendered = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
                        samples.append(contentsOf: rendered)
                    }
                    let window = Array(samples[Int(0.1 * Self.sampleRate) ..< Int(0.4 * Self.sampleRate)])
                    return Self.fundamental(of: window, from: 300, to: 600)
                }

                /// The frequency in `low…high` Hz whose period best repeats `signal` (normalized autocorrelation),
                /// refined between neighboring lags by a parabola through the peak.
                private static func fundamental(of signal: [Float], from low: Double, to high: Double) -> Double {
                    let minLag = Int(sampleRate / high)
                    let maxLag = Int(sampleRate / low)
                    func correlation(_ lag: Int) -> Double {
                        var sum = 0.0, energyA = 0.0, energyB = 0.0
                        for index in 0 ..< signal.count - lag {
                            let first = Double(signal[index]), second = Double(signal[index + lag])
                            sum += first * second
                            energyA += first * first
                            energyB += second * second
                        }
                        return sum / max(Double.ulpOfOne, (energyA * energyB).squareRoot())
                    }
                    let scores = (minLag - 1 ... maxLag + 1).map(correlation)
                    var best = 1
                    for index in 1 ..< scores.count - 1 where scores[index] > scores[best] {
                        best = index
                    }
                    let (left, center, right) = (scores[best - 1], scores[best], scores[best + 1])
                    let denominator = left - 2 * center + right
                    let shift = denominator == 0 ? 0 : 0.5 * (left - right) / denominator
                    return sampleRate / (Double(minLag - 1 + best) + shift)
                }

                @Test(
                    "a live quarter-tone bend sounds 50 cents off, whatever sensitivity the channel was left at",
                    .enabled(if: soundfontAvailable),
                )
                func quarterToneBendSoundsAQuarterTone() async throws {
                    let plain = try await renderedFrequency(wheel: UInt16(MidiEvent.pitchBendCenter))
                    let bent = try await renderedFrequency(wheel: UInt16(MidiEvent.pitchBendValue(cents: -50)))
                    let cents = 1200 * log2(bent / plain)
                    #expect(abs(plain - 440) < 440 * 0.01, "A4 rendered at \(plain) Hz; the measurement is off")
                    #expect(abs(cents + 50) < 5, "a −50 ¢ wheel sounded \(cents) ¢ (\(plain) Hz → \(bent) Hz)")
                }
            }
        }
    #endif
#endif
