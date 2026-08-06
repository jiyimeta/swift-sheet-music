#if !os(Android)
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
                #expect(PlaybackEngine.peakAmplitude(in: buffer) == 0.7)
            }

            @Test("peak uses magnitude, so a negative trough counts")
            func peakUsesMagnitude() throws {
                let buffer = try makeBuffer([[0.1, -0.9, 0.25]])
                #expect(PlaybackEngine.peakAmplitude(in: buffer) == 0.9)
            }

            /// The mix is stereo by the time it reaches `sumMixer`, and a
            /// peak that only exists in one channel still clips.
            @Test("peak spans every channel")
            func peakSpansChannels() throws {
                let buffer = try makeBuffer([[0.1, 0.2], [0.3, 0.8]])
                #expect(PlaybackEngine.peakAmplitude(in: buffer) == 0.8)
            }

            @Test("silence peaks at zero")
            func silenceIsZero() throws {
                let buffer = try makeBuffer([[0, 0, 0]])
                #expect(PlaybackEngine.peakAmplitude(in: buffer) == 0)
            }

            /// Overshoot must be reported as-is rather than clamped: the
            /// whole point of the meter is to show how far past full
            /// scale the master gain has pushed the mix.
            @Test("peak reports overshoot past full scale")
            func reportsOvershoot() throws {
                let buffer = try makeBuffer([[0.5, 1.8]])
                #expect(PlaybackEngine.peakAmplitude(in: buffer) == 1.8)
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

    private struct NullMeterResolver: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
