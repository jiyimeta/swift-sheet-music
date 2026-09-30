/// One level reading of the mix, in linear amplitude where `1.0` is
/// 0 dBFS.
///
/// The two numbers answer different questions and are easy to confuse.
/// `peak` is what clips — it decides how much master gain the mix can
/// still take. `rms` is what sounds loud. Their ratio is the crest
/// factor, and a wide one is why a mix can sit right at the ceiling and
/// still feel quiet: raising the gain cannot fix that, because `peak`
/// hits the ceiling long before `rms` becomes satisfying.
public struct MixLevel: Sendable, Equatable {
    /// Largest sample magnitude in the buffer. Unclamped, so a value
    /// over `1.0` reports real overshoot past full scale.
    public let peak: Float
    /// Root mean square across every channel and frame.
    public let rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }
}
