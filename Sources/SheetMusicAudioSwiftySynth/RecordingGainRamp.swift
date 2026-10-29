/// A track's gain as the render applies it. The engine hands a mute, a solo or a volume change over as a new gain for
/// the same track; stepping to it would click, so the render heads for it linearly over the recording fade instead.
/// Lives with the track's render state and is carried with its playhead through a same-id `setRecordingTracks`.
/// Allocation-free.
struct RecordingGainRamp {
    /// The gain the ramp heads for: the last one the track was handed.
    private(set) var target: Float
    /// The gain of the last frame rendered.
    private(set) var current: Float
    private var step: Float = 0
    /// Frames left until `current` reaches `target`; 0 when it has.
    private var remaining = 0

    /// A ramp already at `gain`: a new track starts at its gain, as it fades in from silence anyway.
    init(gain: Float) {
        target = gain
        current = gain
    }

    /// Heads for `gain` from the current gain over `frames` frames. Nothing changes when it already heads there.
    mutating func head(for gain: Float, frames: Int) {
        guard gain != target else { return }
        target = gain
        remaining = max(1, frames)
        step = (gain - current) / Float(remaining)
    }

    /// The gain of the next frame, which it then becomes.
    mutating func next() -> Float {
        advance(by: 1)
        return current
    }

    /// `frames` frames go by.
    mutating func advance(by frames: Int) {
        guard remaining > 0, frames > 0 else { return }
        if frames >= remaining {
            current = target
            remaining = 0
        } else {
            current += step * Float(frames)
            remaining -= frames
        }
    }

    /// Nothing sounds through it now or later: at 0 and heading nowhere else.
    var isSilent: Bool {
        remaining == 0 && current == 0
    }

    /// Jumps to `gain`, for a track whose recording is silent anyway (a pause, a stop, a load): it fades in afterwards.
    mutating func settle(at gain: Float) {
        target = gain
        current = gain
        remaining = 0
    }
}
