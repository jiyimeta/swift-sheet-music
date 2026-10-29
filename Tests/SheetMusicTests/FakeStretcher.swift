#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import SheetMusicAudioCore

    /// A varispeed stand-in for a `RecordingStretcher` that records every call. It keeps all the input it was fed and
    /// plays it back `inputLatency + outputLatency × rate` frames behind its input cursor, `rate` being the last
    /// seek's, so a caller that does not feed far enough ahead hears its input late. No DSP: the output is the input
    /// at that position, linearly interpolated, at whatever speed it is fed.
    ///
    /// Allocates on the render thread, which a real stretcher must not; it exists to pin the render's rules.
    final class FakeStretcher: RecordingStretcher {
        enum Call: Equatable {
            case reset
            case transpose(Double)
            case seek(frames: Int, rate: Double)
            case process(input: Int, output: Int)
        }

        let inputLatency: Int
        let outputLatency: Int
        /// Frames `seekLength(rate:)` asks for beyond the latency.
        let seekHistory: Int
        private(set) var calls: [Call] = []
        /// The first sample of every seek's input, in order: where each seek started reading.
        private(set) var seekStarts: [Float] = []
        private var left: [Float] = []
        private var right: [Float] = []
        private var rate = 1.0

        init(inputLatency: Int, outputLatency: Int, seekHistory: Int = 64) {
            self.inputLatency = inputLatency
            self.outputLatency = outputLatency
            self.seekHistory = seekHistory
        }

        var processedInput: Int {
            calls.reduce(0) { total, call in
                if case let .process(input, _) = call { total + input } else { total }
            }
        }

        var processedOutput: Int {
            calls.reduce(0) { total, call in
                if case let .process(_, output) = call { total + output } else { total }
            }
        }

        var seeks: [Call] {
            calls.filter { if case .seek = $0 { true } else { false } }
        }

        func seekLength(rate: Double) -> Int {
            inputLatency + Int((Double(outputLatency) * rate).rounded(.up)) + seekHistory
        }

        func setTransposeSemitones(_ semitones: Double) {
            calls.append(.transpose(semitones))
        }

        func reset() {
            calls.append(.reset)
            left = []
            right = []
        }

        func seek(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, rate: Double) {
            calls.append(.seek(frames: frames, rate: rate))
            seekStarts.append(frames > 0 ? left[0] : 0)
            self.left = Array(UnsafeBufferPointer(start: left, count: frames))
            self.right = Array(UnsafeBufferPointer(start: right, count: frames))
            self.rate = rate
        }

        func process(
            inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>, inputFrames: Int,
            outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, outputFrames: Int,
        ) {
            calls.append(.process(input: inputFrames, output: outputFrames))
            let cursor = Double(left.count)
            left += UnsafeBufferPointer(start: inputLeft, count: inputFrames)
            right += UnsafeBufferPointer(start: inputRight, count: inputFrames)
            let lag = Double(inputLatency) + Double(outputLatency) * rate
            let perFrame = outputFrames > 0 ? Double(inputFrames) / Double(outputFrames) : 0
            for frame in 0 ..< outputFrames {
                let position = cursor + Double(frame) * perFrame - lag
                outputLeft[frame] = Self.sample(left, at: position)
                outputRight[frame] = Self.sample(right, at: position)
            }
        }

        private static func sample(_ samples: [Float], at position: Double) -> Float {
            guard position >= 0, position < Double(samples.count - 1) else { return 0 }
            let index = Int(position)
            let fraction = Float(position - Double(index))
            return samples[index] + (samples[index + 1] - samples[index]) * fraction
        }
    }

    /// The stretchers a factory made, in order, so a test can read their calls after rendering. Rendering in these
    /// tests is offline and synchronous on the test's own thread, so nothing reads and writes it at once.
    final class FakeStretcherRecorder: @unchecked Sendable {
        private(set) var made: [FakeStretcher] = []
        let inputLatency: Int
        let outputLatency: Int

        init(inputLatency: Int = 300, outputLatency: Int = 200) {
            self.inputLatency = inputLatency
            self.outputLatency = outputLatency
        }

        var factory: RecordingStretcherFactory {
            RecordingStretcherFactory { [self] _ in
                let stretcher = FakeStretcher(inputLatency: inputLatency, outputLatency: outputLatency)
                made.append(stretcher)
                return stretcher
            }
        }
    }
#endif
