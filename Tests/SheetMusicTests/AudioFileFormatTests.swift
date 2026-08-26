#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioCore
    import Testing

    @Suite("AudioFileFormat")
    struct AudioFileFormatTests {
        @Test("PCMOptions has CD-quality defaults")
        func pcmDefaults() {
            let opts = PCMOptions()
            #expect(opts.sampleRate == 44100)
            #expect(opts.bitDepth == .int16)
            #expect(opts.channels == .stereo)
        }

        @Test("CompressedOptions has 192 kbps stereo defaults")
        func compressedDefaults() {
            let opts = CompressedOptions()
            #expect(opts.sampleRate == 44100)
            #expect(opts.bitRate == 192_000)
            #expect(opts.channels == .stereo)
        }

        @Test("Bare-case construction uses default-initialized payload")
        func bareCaseUsesDefaults() {
            let wav = AudioFileFormat.wav()
            if case let .wav(opts) = wav {
                #expect(opts.sampleRate == 44100)
                #expect(opts.bitDepth == .int16)
            } else {
                Issue.record("Expected .wav case")
            }
        }

        @Test("Mp3 case is constructable on all platforms (runtime-gated elsewhere)")
        func mp3CaseExists() {
            _ = AudioFileFormat.mp3(CompressedOptions(bitRate: 128_000))
        }

        @Test("AudioChannelCount raw values match channel counts")
        func channelCountRaws() {
            #expect(AudioChannelCount.mono.rawValue == 1)
            #expect(AudioChannelCount.stereo.rawValue == 2)
        }

        @Test("PCMBitDepth includes float32")
        func bitDepthIncludesFloat() {
            #expect(PCMBitDepth.allCases.contains(.float32))
        }
    }
#endif
