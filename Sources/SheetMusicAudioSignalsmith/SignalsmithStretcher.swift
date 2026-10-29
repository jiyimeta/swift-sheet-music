import CSignalsmithStretch
import SheetMusicAudioCore

/// Signalsmith Stretch (MIT, vendored in `CSignalsmithStretch`) as a `RecordingStretcher`, on its default preset: a
/// 120 ms block every 30 ms, so about 60 ms of input and 60 ms of output latency.
final class SignalsmithStretcher: RecordingStretcher {
    private let handle: OpaquePointer
    let inputLatency: Int
    let outputLatency: Int

    /// `cheaper` takes Signalsmith's cheaper preset (100 ms every 40 ms, its work spread across the interval) at the
    /// cost of an interval more output latency.
    init(sampleRate: Double, cheaper: Bool = false) {
        guard let handle = csignalsmith_stretch_create(sampleRate, cheaper) else {
            preconditionFailure("Signalsmith Stretch could not allocate its buffers at \(sampleRate) Hz")
        }
        self.handle = handle
        inputLatency = Int(csignalsmith_stretch_input_latency(handle))
        outputLatency = Int(csignalsmith_stretch_output_latency(handle))
    }

    deinit {
        csignalsmith_stretch_destroy(handle)
    }

    func seekLength(rate: Double) -> Int {
        Int(csignalsmith_stretch_seek_length(handle, rate))
    }

    func setTransposeSemitones(_ semitones: Double) {
        csignalsmith_stretch_set_transpose_semitones(handle, semitones)
    }

    func reset() {
        csignalsmith_stretch_reset(handle)
    }

    func seek(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, rate: Double) {
        csignalsmith_stretch_seek(handle, left, right, Int32(frames), rate)
    }

    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>, inputFrames: Int,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, outputFrames: Int,
    ) {
        csignalsmith_stretch_process(
            handle, inputLeft, inputRight, Int32(inputFrames), outputLeft, outputRight, Int32(outputFrames),
        )
    }
}

extension RecordingStretcherFactory {
    /// Signalsmith Stretch: tempo and transposition that keep a recording's pitch and timing.
    public static var signalsmith: Self {
        Self { sampleRate in SignalsmithStretcher(sampleRate: sampleRate) }
    }
}
