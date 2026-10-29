/// A read-only view of interleaved Int16 stereo frames (frame `i` is `base[2i]` left, `base[2i + 1]` right). The caller
/// keeps `base` alive and `frameCount` frames long for as long as the view is used. Allocation-free, so it is safe to
/// read on the render thread.
package struct PCMFrames {
    let base: UnsafePointer<Int16>
    let frameCount: Int
    let sampleRate: Double

    package init(base: UnsafePointer<Int16>, frameCount: Int, sampleRate: Double) {
        self.base = base
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }

    /// The stereo sample at a fractional frame, linearly interpolated between frames ⌊p⌋ and ⌊p⌋ + 1. Silence outside
    /// `[0, frameCount − 1)` and for a non-finite position; never traps.
    func sample(at frame: Double) -> (left: Float, right: Float) {
        guard frame.isFinite, frame >= 0, frame < Double(frameCount - 1) else { return (0, 0) }
        let index = Int(frame)
        let fraction = Float(frame - Double(index))
        // At most 2 × (frameCount − 1) + 3 samples in: ~115 M for a 20-minute 48 kHz track, well within 32 bits.
        let offset = index * 2
        let left0 = Float(base[offset]) / 32768
        let right0 = Float(base[offset + 1]) / 32768
        let left1 = Float(base[offset + 2]) / 32768
        let right1 = Float(base[offset + 3]) / 32768
        return (left0 + (left1 - left0) * fraction, right0 + (right1 - right0) * fraction)
    }
}
