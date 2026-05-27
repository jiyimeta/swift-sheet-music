import AudioToolbox
import AVFoundation
import Foundation

extension PlaybackEngine {
    /// Set the master output gain — a linear amplitude multiplier
    /// applied to the full mix after per-channel mixing. `1.0` is unity
    /// (bit-for-bit unchanged); the value is clamped to `0.0...3.0`
    /// (300%). Idempotent and cheap, so it is safe to call on every
    /// frame of a slider drag. Persists across `prepare(score:)`.
    public func setMasterGain(_ gain: Float) { // swiftlint:disable:this inclusive_language
        let clamped = max(0, min(3, gain))
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
