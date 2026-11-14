import Foundation
import SheetMusicAudioCore
import SheetMusicAudioSignalsmith
import Testing

/// Signalsmith Stretch as Windows builds it — Signalsmith Linear's own C++ FFT, as on Android, no Accelerate: a tone
/// stretched to another tempo keeps its pitch, and a transposition moves it. Driven directly, block by block; what it
/// sounds like through the playback render is the engine's tests.
struct SignalsmithOnWindowsTests {
    private static let sampleRate = 48000.0
    private static let block = 512

    /// The pitch of `samples` from its zero crossings (rising), in Hz: exact enough for a clean sine.
    private static func pitch(_ samples: ArraySlice<Float>) -> Double {
        var crossings: [Int] = []
        var previous = samples.first ?? 0
        for (index, sample) in zip(samples.indices, samples) {
            if previous < 0, sample >= 0 { crossings.append(index) }
            previous = sample
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 2 else { return 0 }
        return Double(crossings.count - 1) / (Double(last - first) / sampleRate)
    }

    /// Feeds a 440 Hz tone through a fresh stretcher at `rate` (input frames per output frame), transposed by
    /// `semitones`, and returns `seconds` of the left output.
    private static func stretch(rate: Double, semitones: Double, seconds: Double) -> [Float] {
        let stretcher = RecordingStretcherFactory.signalsmith.make(sampleRate)
        stretcher.setTransposeSemitones(semitones)
        let outputFrames = Int(seconds * sampleRate)
        var output = [Float](repeating: 0, count: outputFrames)
        let inputBlock = Int((Double(block) * rate).rounded())
        var inputLeft = [Float](repeating: 0, count: inputBlock)
        var outLeft = [Float](repeating: 0, count: block)
        var outRight = [Float](repeating: 0, count: block)
        var phase = 0
        var written = 0
        while written + block <= outputFrames {
            for index in 0 ..< inputBlock {
                inputLeft[index] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(phase + index) / sampleRate))
            }
            phase += inputBlock
            stretcher.process(
                inputLeft: inputLeft, inputRight: inputLeft, inputFrames: inputBlock,
                outputLeft: &outLeft, outputRight: &outRight, outputFrames: block,
            )
            output.replaceSubrange(written ..< written + block, with: outLeft)
            written += block
        }
        return output
    }

    @Test
    func `at 70 % a 440 Hz tone stays at 440 Hz`() {
        let output = Self.stretch(rate: 0.7, semitones: 0, seconds: 2)
        let pitch = Self.pitch(output[48000 ..< 72000])
        #expect(abs(pitch - 440) <= 2, "pitch at 70 %: \(pitch) Hz")
        #expect(output[48000 ..< 72000].map(abs).max() ?? 0 > 0.2, "the stretched tone is quiet")
    }

    @Test
    func `+12 semitones moves a 440 Hz tone to 880 Hz`() {
        let output = Self.stretch(rate: 1, semitones: 12, seconds: 2)
        let pitch = Self.pitch(output[48000 ..< 72000])
        #expect(abs(pitch - 880) <= 4, "pitch at +12 semitones: \(pitch) Hz")
    }
}
