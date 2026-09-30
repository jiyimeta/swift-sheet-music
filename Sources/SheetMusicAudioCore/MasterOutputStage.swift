/// What the master chain does with a mix the master gain has pushed past
/// full scale.
///
/// Nothing here can rescue a mix that is already too loud — the device's
/// volume control sits downstream of all of it and can only attenuate.
/// The choice is only about *how* the excess is dealt with, and the
/// options behave very differently once driven.
public enum MasterOutputStage: String, Sendable, CaseIterable { // swiftlint:disable:this inclusive_language
    /// Leave the mix alone. Overshoot survives the graph intact (float32
    /// connections do not clamp) and is clipped where the audio meets the
    /// output device.
    ///
    /// The default, because it is the only option under which the master
    /// gain behaves like a volume control the whole way up: louder in,
    /// louder out. The cost is that past full scale the clipping is hard.
    case none

    /// Bend the peaks with a saturation curve — linear below -3 dBFS,
    /// then asymptotic toward full scale.
    ///
    /// Ordinary playback is untouched, and loudness keeps rising as the
    /// gain goes up, so the control still runs the right way. The cost is
    /// progressive harmonic distortion instead of a hard edge.
    ///
    /// There is deliberately no limiter option (4.0.0 removed Apple's peak limiter): a limiter holds the ceiling by
    /// *reducing gain*, so above unity the master control runs backwards — measured on a steady sine, 8x drive
    /// landed 2.4 dB quieter than 1x, on top of the pumping.
    case softClip
}
