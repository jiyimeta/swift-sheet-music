/// Plays a stereo recording at another speed or pitch with its pitch and timing kept: what a backend reads a recording
/// through when the tempo is not 100 % or the recording is transposed. The render path names only this protocol, so
/// the library behind it can be replaced; `SheetMusicAudioSignalsmith` supplies Signalsmith Stretch's.
///
/// An instance is made on the main actor (`RecordingStretcherFactory`) and released there. Every requirement is then
/// called on the render thread, so none may allocate, lock or block.
///
/// Timing: the output plays the input `inputLatency + outputLatency × rate` frames behind the frame the next input
/// begins at, `rate` being input frames per output frame. A caller that wants output frame `t` to play input frame
/// `p` feeds input from `p + inputLatency + outputLatency × rate` on.
public protocol RecordingStretcher: AnyObject {
    /// Frames between the last input frame fed and the processing position.
    var inputLatency: Int { get }
    /// Output frames between the processing position and the output.
    var outputLatency: Int { get }
    /// How many input frames `seek` takes at `rate`.
    func seekLength(rate: Double) -> Int
    /// Shifts the pitch by `semitones`, leaving the timing alone.
    func setTransposeSemitones(_ semitones: Double)
    /// Forgets every input and output, as a new instance would.
    func reset()
    /// After `reset()`: starts on `frames` (`seekLength(rate:)`) frames of input that end where the next `process`
    /// call's input begins. The next output frame then plays the input `inputLatency + outputLatency × rate` frames
    /// before that end, at full level, as if the stretcher had been playing this input all along.
    func seek(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, rate: Double)
    /// Consumes `inputFrames` and produces `outputFrames`; their ratio is the rate for this call. Input and output
    /// must not overlap.
    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>, inputFrames: Int,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, outputFrames: Int,
    )
}

/// What a host injects into a backend to have recordings stretched: a way to make a `RecordingStretcher` for a sample
/// rate. Called on the main actor only, never on the render thread.
public struct RecordingStretcherFactory: Sendable {
    /// Makes a stretcher for audio at `sampleRate`.
    package let make: @Sendable (_ sampleRate: Double) -> any RecordingStretcher

    public init(make: @escaping @Sendable (_ sampleRate: Double) -> any RecordingStretcher) {
        self.make = make
    }
}
