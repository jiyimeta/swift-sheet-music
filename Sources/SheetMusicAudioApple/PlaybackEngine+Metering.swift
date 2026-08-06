import Accelerate
import AVFoundation
import Foundation

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

extension PlaybackEngine {
    /// Start reporting the mix's level, so a host can show a meter — or
    /// measure how much headroom it has left before the master gain
    /// pushes the mix past full scale.
    ///
    /// `handler` receives a `MixLevel` per captured buffer. The device's
    /// volume control sits *downstream* of this point and can only
    /// attenuate, so a peak over `1.0` cannot be rescued by turning the
    /// device down — headroom has to be found here.
    ///
    /// The tap sits on `sumMixer`: after the master gain and after the
    /// metronome is summed in, but *before* the limiter, so the reported
    /// level is the true pre-limiting one rather than the limiter's
    /// clamped output.
    ///
    /// `handler` is called on an audio-processing thread, not the main
    /// actor — hop before touching UI. Buffers arrive only while audio is
    /// flowing.
    ///
    /// Starting again replaces the previous handler.
    public func startLevelMonitoring(_ handler: @escaping @Sendable (MixLevel) -> Void) {
        // `installTap` traps if the bus is already tapped, so re-arming
        // has to remove the previous tap rather than stack onto it.
        stopLevelMonitoring()
        sumMixer.installTap(
            onBus: 0, bufferSize: 1024, format: nil,
            block: Self.makeTapBlock(handler),
        )
        isLevelMonitoring = true
    }

    /// Remove the level tap. No-op when not monitoring.
    public func stopLevelMonitoring() {
        guard isLevelMonitoring else { return }
        sumMixer.removeTap(onBus: 0)
        isLevelMonitoring = false
    }

    /// Build the tap block that feeds `handler`.
    ///
    /// `nonisolated` is load-bearing, not decoration. `AVAudioNodeTapBlock`
    /// is not `@Sendable`, so a closure literal written inside this
    /// `@MainActor` class's isolation *inherits* that isolation — and
    /// AVFoundation calls the tap from its own realtime-messenger queue.
    /// The result is an actor-executor assertion (EXC_BREAKPOINT) the
    /// instant audio starts flowing, the same trap `previewGeneration`
    /// documents for `DispatchWorkItem`. Building the block from a
    /// `nonisolated` context leaves it no isolation to inherit.
    nonisolated static func makeTapBlock(
        _ handler: @escaping @Sendable (MixLevel) -> Void,
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in handler(level(in: buffer)) }
    }

    /// Peak and RMS across every channel and frame of `buffer`.
    ///
    /// Channels are pooled by mean square before the square root, which
    /// is what makes a signal present in one channel of a stereo pair
    /// read `0.707` rather than `0.5` — averaging per-channel RMS values
    /// instead would understate it. `nonisolated` because the tap calls
    /// this from an audio-processing thread.
    nonisolated static func level(in buffer: AVAudioPCMBuffer) -> MixLevel {
        guard let data = buffer.floatChannelData else {
            return MixLevel(peak: 0, rms: 0)
        }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else {
            return MixLevel(peak: 0, rms: 0)
        }

        var peak: Float = 0
        var meanSquareSum: Float = 0
        for channel in 0 ..< channels {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[channel], 1, &channelPeak, frames)
            peak = max(peak, channelPeak)

            var channelMeanSquare: Float = 0
            vDSP_measqv(data[channel], 1, &channelMeanSquare, frames)
            meanSquareSum += channelMeanSquare
        }
        return MixLevel(
            peak: peak, rms: (meanSquareSum / Float(channels)).squareRoot(),
        )
    }
}
