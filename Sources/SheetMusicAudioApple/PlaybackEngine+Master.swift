import AudioToolbox
import AVFoundation
import Foundation

extension PlaybackEngine {
    /// Set the master output gain — a linear amplitude multiplier
    /// applied to the full mix after per-channel mixing. `1.0` is unity
    /// (bit-for-bit unchanged). Negative values are clamped to zero;
    /// there is no ceiling. Idempotent and cheap, so it is safe to call
    /// on every frame of a slider drag. Persists across
    /// `prepare(score:)`.
    ///
    /// The ceiling used to be 3.0. That was a product decision living in
    /// the wrong layer: how loud playback should be depends on the
    /// synth backend's own output level and on what the host is trying
    /// to sound like, neither of which this engine can judge. A host
    /// calibrating a quiet backend against a louder reference can
    /// legitimately need more than 3×, and being refused left it with no
    /// recourse. The downstream peak limiter still keeps a large boost
    /// from hard-clipping, so the host — not this call — owns the
    /// trade-off between loudness and limiting.
    public func setMasterGain(_ gain: Float) { // swiftlint:disable:this inclusive_language
        let clamped = max(0, gain)
        masterGain = clamped
        scoreGainMixer.outputVolume = clamped
    }

    /// Attach the master output stage and wire it once:
    /// `scoreGainMixer → sumMixer → limiter → mainMixerNode`. The score
    /// synth is connected to `scoreGainMixer` in `prepareSynth`; the
    /// metronome sampler connects to `sumMixer` from
    /// `MetronomeController`. Called from `init`, so the chain — and
    /// therefore `masterGain` — outlives every `prepare(score:)`.
    func buildMasterChain() { // swiftlint:disable:this inclusive_language
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(limiter)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = masterGain
    }

    /// Build a brick-wall peak limiter (`kAudioUnitSubType_PeakLimiter`,
    /// Apple). Default attack / decay / pre-gain are transparent below
    /// full-scale, so the limiter only engages once the master gain
    /// pushes the summed signal past 0 dBFS.
    static func makePeakLimiter() -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }

    /// Test-only read-back of the gain actually applied to the audio
    /// node, distinct from the `masterGain` stored mirror.
    var scoreGainMixerOutputVolume: Float {
        scoreGainMixer.outputVolume
    }
}
