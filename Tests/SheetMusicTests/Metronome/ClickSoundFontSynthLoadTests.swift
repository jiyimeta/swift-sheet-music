#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioCore
    import Testing

    struct ClickSoundFontSynthLoadTests {
        /// Build a click SF2 with audibly non-zero samples, load it into an
        /// AVAudioUnitSampler (percussion bank), and offline-render note 76 —
        /// the strong click. A non-silent buffer proves the SF2 parsed and the
        /// note-to-sample mapping resolved.
        @Test func generatedSoundFontRendersNote76() throws {
            // ~50 ms square-ish wave at 44.1 kHz so there is real energy.
            let count = 2205
            let strong = (0 ..< count).map { i -> Int16 in
                i % 2 == 0 ? 12000 : -12000
            }
            let sf2 = ClickSoundFontBuilder.build(
                strong: strong, strongRate: 44100, weak: strong, weakRate: 44100,
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("click-\(UUID().uuidString).sf2")
            try sf2.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let engine = AVAudioEngine()
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)

            // SF2 bank 128 maps to AUSampler's percussion bank MSB (0x78).
            try sampler.loadSoundBankInstrument(
                at: url,
                program: 0,
                bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
                bankLSB: 0,
            )

            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 4096,
            )
            try engine.start()

            sampler.startNote(76, withVelocity: 100, onChannel: 0)

            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
            ))
            var peak: Float = 0
            for _ in 0 ..< 12 {
                let status = try engine.renderOffline(4096, to: buffer)
                if status == .success, let ch = buffer.floatChannelData {
                    for i in 0 ..< Int(buffer.frameLength) {
                        peak = max(peak, abs(ch[0][i]))
                    }
                }
            }
            engine.stop()
            engine.disableManualRenderingMode()

            #expect(peak > 0.0001)
        }
    }
#endif
