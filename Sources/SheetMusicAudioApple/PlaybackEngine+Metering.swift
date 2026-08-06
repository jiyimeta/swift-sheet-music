import Accelerate
import AVFoundation
import Foundation

extension PlaybackEngine {
    /// Start reporting the mix's peak level, so a host can show a level
    /// meter — or measure how much headroom it has left before the
    /// master gain pushes the mix past full scale.
    ///
    /// `handler` receives the peak linear amplitude of each captured
    /// buffer: `1.0` is 0 dBFS, the largest value the output can carry.
    /// Anything above `1.0` is already past full scale and only survives
    /// as far as the limiter; it will not reach the speaker intact. The
    /// device's volume control sits *downstream* of this point and can
    /// only attenuate, so a peak over `1.0` cannot be rescued by turning
    /// the device down — headroom has to be found here.
    ///
    /// The tap sits on `sumMixer`: after the master gain and after the
    /// metronome is summed in, but *before* the limiter, so the reported
    /// peak is the true pre-limiting level rather than the limiter's
    /// clamped output.
    ///
    /// `handler` is called on an audio-processing thread, not the main
    /// actor — hop before touching UI. Buffers arrive only while audio is
    /// flowing.
    ///
    /// Starting again replaces the previous handler.
    public func startLevelMonitoring(_ handler: @escaping @Sendable (Float) -> Void) {
        // `installTap` traps if the bus is already tapped, so re-arming
        // has to remove the previous tap rather than stack onto it.
        stopLevelMonitoring()
        sumMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            handler(PlaybackEngine.peakAmplitude(in: buffer))
        }
        isLevelMonitoring = true
    }

    /// Remove the peak-level tap. No-op when not monitoring.
    public func stopLevelMonitoring() {
        guard isLevelMonitoring else { return }
        sumMixer.removeTap(onBus: 0)
        isLevelMonitoring = false
    }

    /// Largest sample magnitude across every channel and frame of
    /// `buffer`. Deliberately unclamped: a value over `1.0` is exactly
    /// the overshoot the caller needs to see. `nonisolated` because the
    /// tap calls it from an audio-processing thread.
    nonisolated static func peakAmplitude(in buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        for channel in 0 ..< Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[channel], 1, &channelPeak, frames)
            peak = max(peak, channelPeak)
        }
        return peak
    }
}
