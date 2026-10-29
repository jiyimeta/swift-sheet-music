/// Where one track is being read and whether a crossfade is under way. Advanced one output frame at a time by
/// `render`; allocation-free.
package struct RecordingPlayhead {
    /// A source position this far (frames) from the continuation is a discontinuity.
    static let jumpToleranceFrames = 2.0

    /// Whether the previous output frame read the recording (`false` after silence, a reset).
    private var hasSource = false
    /// Where the next output frame reads if nothing jumped.
    private var nextSourceFrame: Double = 0
    private var fadeFramesRemaining = 0
    /// The stream being faded out is silence (a fade-in).
    private var fadeFromSilence = false
    /// The faded-out stream's position, advancing with it.
    private var fadeOldSourceFrame: Double = 0

    package init() {}

    /// One output frame: `target` is where the recording should be read now (`nil` = silence) and `step` how far the
    /// read advances per output frame. A target more than `jumpToleranceFrames` from the continuation starts a
    /// `fadeFrames`-long linear crossfade from the continuation, which keeps advancing under the fade. A jump arriving
    /// mid-fade restarts from the newer stream's continuation (the older one is dropped). Silence fades the recording
    /// out, and audio after silence fades in.
    package mutating func render(
        target: Double?, step: Double, from source: PCMFrames, fadeFrames: Int,
    ) -> (left: Float, right: Float) {
        let fadeLength = max(1, fadeFrames)
        let continuous: Bool = if let target {
            hasSource && abs(target - nextSourceFrame) <= Self.jumpToleranceFrames
        } else {
            !hasSource
        }
        if !continuous {
            fadeFromSilence = !hasSource
            fadeOldSourceFrame = nextSourceFrame
            fadeFramesRemaining = fadeLength
        }

        var outL: Float = 0
        var outR: Float = 0
        var weight: Float = 1
        if fadeFramesRemaining > 0 {
            weight = 1 - Float(fadeFramesRemaining) / Float(fadeLength)
            if !fadeFromSilence {
                let old = source.sample(at: fadeOldSourceFrame)
                outL += (1 - weight) * old.left
                outR += (1 - weight) * old.right
            }
            fadeOldSourceFrame += step
            fadeFramesRemaining -= 1
        }
        if let target {
            let new = source.sample(at: target)
            outL += weight * new.left
            outR += weight * new.right
            nextSourceFrame = target + step
            hasSource = true
        } else {
            hasSource = false
        }
        return (outL, outR)
    }

    /// A transport move or a stretch in which the track was not mixed: the next frame fades in.
    package mutating func reset() {
        hasSource = false
        fadeFramesRemaining = 0
    }
}
