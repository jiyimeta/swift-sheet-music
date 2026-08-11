import Foundation

/// A saturation curve for the master output stage: linear below a knee,
/// then bending asymptotically toward full scale.
///
/// It exists as an alternative to the peak limiter, whose gain reduction
/// makes the master gain control run *backwards* above unity — measured
/// on a steady sine, driving the limiter with 8x input yields a quieter
/// output than 1x does. A control that reverses direction is not
/// something a listener can reason about.
///
/// This curve is strictly monotonic instead: louder in is always louder
/// out, all the way up, and the price is progressive harmonic
/// distortion rather than a moving gain. Below the knee it does nothing
/// at all, so ordinary playback is bit-for-bit untouched.
enum SoftClip {
    /// Where the curve leaves the linear region, in linear amplitude.
    /// -3 dBFS: high enough that normal material never reaches it, low
    /// enough to leave room to bend in before full scale.
    static let defaultKnee: Float = 0.7071068

    /// Shape one sample.
    ///
    /// Below `knee` the sample is returned unchanged. Above it the excess
    /// is passed through `tanh`, scaled so the curve leaves the knee with
    /// slope 1 (no audible kink) and approaches — but never reaches —
    /// full scale. At exactly 0 dBFS in, the default knee gives about
    /// -0.6 dB out.
    ///
    /// A `knee` at or above full scale leaves nothing to bend into, so
    /// the curve degenerates to a hard clip rather than dividing by zero.
    static func apply(_ sample: Float, knee: Float = defaultKnee) -> Float {
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        guard knee < 1 else {
            return sample < 0 ? -1 : 1
        }
        let headroom = 1 - knee
        let shaped = knee + headroom * tanh((magnitude - knee) / headroom)
        return sample < 0 ? -shaped : shaped
    }
}
