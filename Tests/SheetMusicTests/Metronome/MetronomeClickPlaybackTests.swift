#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMSCX
    import Testing

    @Suite("Metronome click playback (Apple)")
    @MainActor
    struct MetronomeClickPlaybackTests {
        private struct SilentResolver: SoundfontResolver {
            func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
                nil
            }

            var defaultGMSoundfontURL: URL? {
                nil
            }
        }

        private struct FixedProvider: MetronomeClickProvider {
            let source: MetronomeClickSource
            func metronomeClickSource() -> MetronomeClickSource {
                source
            }
        }

        private func loadMidi01() throws -> Score {
            let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
            return try MSCXParser.parse(contentsOf: url)
        }

        private func writeClickWav() throws -> URL {
            let wave = (0 ..< 4410).map { Int16($0 % 2 == 0 ? 14000 : -14000) }
            let data = WavTestSupport.pcm16(interleaved: wave, channels: 1, sampleRate: 44100)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("click-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func peakOfWav(at url: URL) throws -> Float {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length),
            ))
            try file.read(into: buffer)
            // `processingFormat` is always deinterleaved float32, so
            // `floatChannelData` is non-nil; require it so a future format
            // change fails loudly instead of silently reporting peak 0.
            let data = try #require(buffer.floatChannelData)
            var peak: Float = 0
            for c in 0 ..< Int(format.channelCount) {
                for i in 0 ..< Int(buffer.frameLength) {
                    peak = max(peak, abs(data[c][i]))
                }
            }
            return peak
        }

        @Test("custom click is audible in export while the score is silent")
        func clickAudibleInExport() async throws {
            let score = try loadMidi01()
            let click = try writeClickWav()
            defer { try? FileManager.default.removeItem(at: click) }

            let engine = PlaybackEngine(
                soundfontResolver: SilentResolver(),
                metronomeClickProvider: FixedProvider(
                    source: .clickSamples(strong: click, weak: click),
                ),
            )
            try engine.prepare(score: score)
            engine.setMetronomeEnabled(true)

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("metro-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: out) }
            try await engine.exportAudioFile(
                to: out, score: score,
                format: .wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo)),
            )

            let peak = try peakOfWav(at: out)
            #expect(peak > 0.0001)
        }

        @Test("no provider keeps the engine working (backward compatible)")
        func noProviderStillPrepares() throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)
            #expect(engine.state == .stopped)
        }
    }
#endif
