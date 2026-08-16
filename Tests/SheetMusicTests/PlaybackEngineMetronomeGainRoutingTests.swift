#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMSCX
    import Testing

    /// The metronome is scaled by the master gain, on both synth paths.
    ///
    /// It used to join the master stage at `sumMixer` — downstream of
    /// `scoreGainMixer` — so the click was a fixed reference the master gain
    /// did not touch. That only ever held on the AUMIDISynth path: an injected
    /// `SynthBackend` mixes its click inside its own render block and hands
    /// back one node, which connects to `scoreGainMixer`, so there the click
    /// always tracked the gain. The two paths are now unified on tracking.
    extension AudioEngineSerial {
        @Suite("Metronome tracks the master gain")
        @MainActor
        struct PlaybackEngineMetronomeGainRoutingTests {
            /// The live graph itself — the wiring the export only mirrors.
            @Test("The live click joins the master chain at the gain stage")
            func liveMetronomeFeedsTheGainStage() throws {
                let engine = PlaybackEngine(soundfontResolver: SilentResolver())
                // Explicit, not left to ARC: an engine torn down while the next
                // test initializes its own aborts the whole process in
                // CoreAudio (see `AudioEngineSerial`).
                defer { engine.teardown() }
                try engine.prepare(score: loadMidi01())

                let destination = try #require(engine.metronomeOutputDestination)
                #expect(destination === engine.scoreGainMixer)
                #expect(destination !== engine.sumMixer)
            }

            /// And the samples agree. Read back through the export, the only
            /// way to get the mix as numbers.
            @Test("Doubling the master gain doubles the click")
            func clickIsScaledByMasterGain() async throws { // swiftlint:disable:this inclusive_language
                let click = try writeClickWav()
                defer { try? FileManager.default.removeItem(at: click) }

                let quiet = try await clickOnlyExportPeak(masterGain: 0.25, click: click)
                let loud = try await clickOnlyExportPeak(masterGain: 0.5, click: click)

                // The click sounded at all — otherwise both peaks would be 0
                // and the ratio below would be vacuously satisfied.
                #expect(quiet > 0.001)
                // Loose bound: two independent offline passes, so sample-exact
                // equality is not the claim — "it moved, and by about 2x" is.
                #expect(loud > quiet * 1.8)
                #expect(loud < quiet * 2.2)
            }

            /// Peak of an export in which the score is silent (the resolver
            /// hands back no SoundFont) and the only thing sounding is the
            /// host's click. Gains stay well under unity so the `.wav` writer's
            /// integer clamp can't be what limits the louder pass.
            private func clickOnlyExportPeak(
                masterGain: Float, // swiftlint:disable:this inclusive_language
                click: URL,
            ) async throws -> Float {
                let score = try loadMidi01()
                // No backend injected: this exercises the AUMIDISynth path,
                // the one whose routing this change moved.
                let engine = PlaybackEngine(
                    soundfontResolver: SilentResolver(),
                    metronomeClickProvider: FixedClickProvider(
                        source: .clickSamples(strong: click, weak: click),
                    ),
                )
                defer { engine.teardown() }
                try engine.prepare(score: score)
                engine.setMetronomeEnabled(true)
                engine.setMasterGain(masterGain)

                let url = AudioExportProbe.temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )
                return try AudioExportProbe.peakAmplitude(of: url)
            }

            private func loadMidi01() throws -> Score {
                let url = try #require(
                    Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
                )
                return try MSCXParser.parse(contentsOf: url)
            }

            /// A square-ish tone loud enough to measure. Mirrors the fixture in
            /// `MetronomeClickPlaybackTests`.
            private func writeClickWav() throws -> URL {
                let wave = (0 ..< 4410).map { Int16($0 % 2 == 0 ? 14000 : -14000) }
                let data = WavTestSupport.pcm16(
                    interleaved: wave, channels: 1, sampleRate: 44100,
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("click-\(UUID().uuidString).wav")
                try data.write(to: url)
                return url
            }
        }
    }

    /// Resolves nothing, so the score itself is silent and every sample in the
    /// export belongs to the click.
    private struct SilentResolver: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }

    private struct FixedClickProvider: MetronomeClickProvider {
        let source: MetronomeClickSource
        func metronomeClickSource() -> MetronomeClickSource {
            source
        }
    }
#endif
