#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import Testing

    extension AudioEngineSerial {
        struct MetronomeClickResolverTests {
            private struct StubResolver: SoundfontResolver {
                let drumURL: URL?
                let gmURL: URL?
                func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
                    isDrums ? drumURL : nil
                }

                var defaultGMSoundfontURL: URL? {
                    gmURL
                }
            }

            private struct FixedProvider: MetronomeClickProvider {
                let source: MetronomeClickSource
                func metronomeClickSource() -> MetronomeClickSource {
                    source
                }
            }

            private func writeWav(_ samples: [Int16], rate: UInt32) throws -> URL {
                let data = WavTestSupport.pcm16(
                    interleaved: samples, channels: 1, sampleRate: rate,
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("click-\(UUID().uuidString).wav")
                try data.write(to: url)
                return url
            }

            @Test func defaultGMReturnsDrumKitURL() {
                let drum = URL(fileURLWithPath: "/tmp/gm-drums.sf2")
                let resolver = MetronomeClickResolver(
                    provider: nil,
                    soundfontResolver: StubResolver(drumURL: drum, gmURL: nil),
                )
                #expect(resolver.resolvedSoundFontURL() == drum)
            }

            @Test func soundFontSourceReturnedVerbatim() {
                let sf2 = URL(fileURLWithPath: "/tmp/custom.sf2")
                let resolver = MetronomeClickResolver(
                    provider: FixedProvider(source: .soundFont(sf2)),
                    soundfontResolver: StubResolver(drumURL: nil, gmURL: nil),
                )
                #expect(resolver.resolvedSoundFontURL() == sf2)
            }

            @Test func clickSamplesGeneratesLoadablePlayableSF2() throws {
                let wave = (0 ..< 2205).map { Int16($0 % 2 == 0 ? 12000 : -12000) }
                let strong = try writeWav(wave, rate: 44100)
                let weak = try writeWav(wave, rate: 44100)
                defer {
                    try? FileManager.default.removeItem(at: strong)
                    try? FileManager.default.removeItem(at: weak)
                }
                let resolver = MetronomeClickResolver(
                    provider: FixedProvider(source: .clickSamples(strong: strong, weak: weak)),
                    soundfontResolver: StubResolver(drumURL: nil, gmURL: nil),
                )
                let url = try #require(resolver.resolvedSoundFontURL())
                defer { try? FileManager.default.removeItem(at: url) }
                #expect(FileManager.default.fileExists(atPath: url.path))

                let engine = AVAudioEngine()
                let sampler = AVAudioUnitSampler()
                engine.attach(sampler)
                engine.connect(sampler, to: engine.mainMixerNode, format: nil)
                try sampler.loadSoundBankInstrument(
                    at: url, program: 0,
                    bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0,
                )
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
                try engine.start()
                sampler.startNote(76, withVelocity: 100, onChannel: 0)
                let buffer = try #require(AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
                ))
                var peak: Float = 0
                for _ in 0 ..< 12 {
                    if try engine.renderOffline(4096, to: buffer) == .success, let ch = buffer.floatChannelData {
                        for i in 0 ..< Int(buffer.frameLength) {
                            peak = max(peak, abs(ch[0][i]))
                        }
                    }
                }
                engine.stop()
                engine.disableManualRenderingMode()
                #expect(peak > 0.0001)
            }

            @Test func clickSamplesCachesGeneratedFile() throws {
                let wave = [Int16](repeating: 5000, count: 100)
                let strong = try writeWav(wave, rate: 44100)
                let weak = try writeWav(wave, rate: 44100)
                defer {
                    try? FileManager.default.removeItem(at: strong)
                    try? FileManager.default.removeItem(at: weak)
                }
                let resolver = MetronomeClickResolver(
                    provider: FixedProvider(source: .clickSamples(strong: strong, weak: weak)),
                    soundfontResolver: StubResolver(drumURL: nil, gmURL: nil),
                )
                let first = try #require(resolver.resolvedSoundFontURL())
                defer { try? FileManager.default.removeItem(at: first) }
                let second = try #require(resolver.resolvedSoundFontURL())
                #expect(first == second)
            }

            @Test func clickSamplesFallsBackToGMOnBadWav() throws {
                let drum = URL(fileURLWithPath: "/tmp/gm-drums.sf2")
                let bad = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bad-\(UUID().uuidString).wav")
                try Data([0x00, 0x01, 0x02, 0x03]).write(to: bad)
                defer { try? FileManager.default.removeItem(at: bad) }
                let resolver = MetronomeClickResolver(
                    provider: FixedProvider(source: .clickSamples(strong: bad, weak: bad)),
                    soundfontResolver: StubResolver(drumURL: drum, gmURL: nil),
                )
                #expect(resolver.resolvedSoundFontURL() == drum)
            }
        }
    }
#endif
