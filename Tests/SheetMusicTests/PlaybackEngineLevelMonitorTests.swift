#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// Unit tests for `PlaybackEngine`'s peak-level metering. The tap
    /// itself only produces buffers while audio is flowing (no audio
    /// device on CI), so these cover the pure peak arithmetic and the
    /// start / stop lifecycle. Real levels are read in the Mac example
    /// app with a GM soundfont.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine level monitor")
        @MainActor
        struct PlaybackEngineLevelMonitorTests {
            @Test("peak is the largest sample magnitude in the buffer")
            func peakFindsLargestMagnitude() throws {
                let buffer = try makeBuffer([[0.1, 0.7, 0.25]])
                #expect(PlaybackEngine.level(in: buffer).peak == 0.7)
            }

            @Test("peak uses magnitude, so a negative trough counts")
            func peakUsesMagnitude() throws {
                let buffer = try makeBuffer([[0.1, -0.9, 0.25]])
                #expect(PlaybackEngine.level(in: buffer).peak == 0.9)
            }

            /// The mix is stereo by the time it reaches `sumMixer`, and a
            /// peak that only exists in one channel still clips.
            @Test("peak spans every channel")
            func peakSpansChannels() throws {
                let buffer = try makeBuffer([[0.1, 0.2], [0.3, 0.8]])
                #expect(PlaybackEngine.level(in: buffer).peak == 0.8)
            }

            @Test("silence reads zero on both meters")
            func silenceIsZero() throws {
                let buffer = try makeBuffer([[0, 0, 0]])
                let level = PlaybackEngine.level(in: buffer)
                #expect(level.peak == 0)
                #expect(level.rms == 0)
            }

            /// Overshoot must be reported as-is rather than clamped: the
            /// whole point of the meter is to show how far past full
            /// scale the master gain has pushed the mix.
            @Test("peak reports overshoot past full scale")
            func reportsOvershoot() throws {
                let buffer = try makeBuffer([[0.5, 1.8]])
                #expect(PlaybackEngine.level(in: buffer).peak == 1.8)
            }

            /// A steady signal has no crest at all, so its RMS is its own
            /// amplitude — the simplest anchor for the arithmetic.
            @Test("a steady signal's RMS equals its amplitude")
            func rmsOfSteadySignal() throws {
                let buffer = try makeBuffer([[0.5, 0.5, 0.5, 0.5]])
                #expect(PlaybackEngine.level(in: buffer).rms.isApproximately(0.5))
            }

            /// RMS squares before averaging, so the sign drops out — a
            /// square wave is as loud as the DC signal of the same height.
            @Test("RMS squares away the sign")
            func rmsIgnoresSign() throws {
                let buffer = try makeBuffer([[0.5, -0.5, 0.5, -0.5]])
                #expect(PlaybackEngine.level(in: buffer).rms.isApproximately(0.5))
            }

            /// One full-scale sample in four is mean-square 0.25, RMS 0.5 —
            /// half the peak. This is the crest factor the meter exists to
            /// expose: a mix can peak near full scale and still be quiet.
            @Test("RMS falls below peak for a spiky signal")
            func rmsFallsBelowPeak() throws {
                let buffer = try makeBuffer([[1, 0, 0, 0]])
                let level = PlaybackEngine.level(in: buffer)
                #expect(level.peak == 1)
                #expect(level.rms.isApproximately(0.5))
            }

            /// Channels are pooled by mean square, not averaged after the
            /// square root — a signal in one channel of a stereo pair reads
            /// 0.707, not 0.5.
            @Test("RMS pools channels by mean square")
            func rmsPoolsChannels() throws {
                let buffer = try makeBuffer([[0, 0], [1, 1]])
                #expect(PlaybackEngine.level(in: buffer).rms.isApproximately(0.7071068))
            }

            /// AVFoundation calls the tap from its own realtime-messenger
            /// queue, never the main actor. A tap block that inherited
            /// `PlaybackEngine`'s `@MainActor` isolation traps with
            /// EXC_BREAKPOINT the moment audio starts flowing — the same
            /// actor-executor assertion `previewGeneration` exists to dodge.
            /// Building the block off the main actor is the whole point, so
            /// this test invokes it off the main actor too.
            @Test("the tap block runs off the main actor")
            func tapBlockRunsOffTheMainActor() async throws {
                let buffer = try makeBuffer([[0.4, -0.4]])
                let received = LevelBox()
                let block = PlaybackEngine.makeTapBlock { received.store($0) }
                let time = AVAudioTime(sampleTime: 0, atRate: 44100)

                await Task.detached { block(buffer, time) }.value

                #expect(received.value?.peak == 0.4)
                #expect(received.value?.rms.isApproximately(0.4) == true)
            }

            @Test("monitoring is off until started")
            func offByDefault() {
                let engine = PlaybackEngine(soundfontResolver: NullMeterResolver())
                #expect(engine.isLevelMonitoring == false)
            }

            @Test("start then stop toggles the monitoring flag")
            func startStopTogglesFlag() {
                let engine = PlaybackEngine(soundfontResolver: NullMeterResolver())

                engine.startLevelMonitoring { _ in }
                #expect(engine.isLevelMonitoring)

                engine.stopLevelMonitoring()
                #expect(engine.isLevelMonitoring == false)
            }

            /// `AVAudioNode.installTap` traps when a bus is already
            /// tapped, so a second `start` must replace the first rather
            /// than stack onto it — a host re-arming its meter on every
            /// view appearance would otherwise crash.
            @Test("starting twice replaces the tap instead of trapping")
            func startingTwiceIsSafe() {
                let engine = PlaybackEngine(soundfontResolver: NullMeterResolver())

                engine.startLevelMonitoring { _ in }
                engine.startLevelMonitoring { _ in }
                #expect(engine.isLevelMonitoring)

                engine.stopLevelMonitoring()
                #expect(engine.isLevelMonitoring == false)
            }

            @Test("stopping without starting is a no-op")
            func stoppingWithoutStartingIsSafe() {
                let engine = PlaybackEngine(soundfontResolver: NullMeterResolver())

                engine.stopLevelMonitoring()
                #expect(engine.isLevelMonitoring == false)
            }
        }
    }

    /// Build a float32 non-interleaved buffer from per-channel samples.
    private func makeBuffer(_ channels: [[Float]]) throws -> AVAudioPCMBuffer {
        let frames = channels[0].count
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false,
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames),
        ))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for (ch, samples) in channels.enumerated() {
            for (i, sample) in samples.enumerated() {
                data[ch][i] = sample
            }
        }
        return buffer
    }

    /// Carries a level reading from the tap's thread back to the test.
    private final class LevelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MixLevel?

        func store(_ level: MixLevel) {
            lock.lock()
            defer { lock.unlock() }
            stored = level
        }

        var value: MixLevel? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    extension Float {
        /// Float RMS goes through a square root, so exact equality is the
        /// wrong assertion for anything but zero.
        fileprivate func isApproximately(_ other: Float) -> Bool {
            abs(self - other) < 1e-5
        }
    }

    private struct NullMeterResolver: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
