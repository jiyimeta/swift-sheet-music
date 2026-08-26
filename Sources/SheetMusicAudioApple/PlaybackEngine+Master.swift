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
    /// recourse. What a large boost then does past full scale is
    /// `masterOutputStage`'s business, not this call's — by default
    /// nothing, so the gain reaches the output device as given.
    public func setMasterGain(_ gain: Float) { // swiftlint:disable:this inclusive_language
        let clamped = max(0, gain)
        masterGain = clamped
        scoreGainMixer.outputVolume = clamped
    }

    /// Choose what — if anything — shapes the mix once the master gain
    /// has pushed it past full scale. Idempotent; persists across
    /// `prepare(score:)`. Switching flips `bypass` on nodes that are
    /// always wired in, so it is safe to call during playback.
    public func setMasterOutputStage(_ stage: MasterOutputStage) { // swiftlint:disable:this inclusive_language
        masterOutputStage = stage
        softClip.bypass = stage != .softClip
        limiter.bypass = stage != .peakLimiter
    }

    /// Attach the master output stage and wire it once:
    /// `scoreGainMixer → sumMixer → softClip → limiter → mainMixerNode`.
    /// The score synth is connected to `scoreGainMixer` in
    /// `prepareSynth`; the metronome sampler connects to the same node
    /// from `MetronomeController`, so the click is scaled by the master
    /// gain too. Called from `init`, so the chain — and
    /// therefore `masterGain` and `masterOutputStage` — outlives every
    /// `prepare(score:)`.
    ///
    /// Both shaping nodes stay in the graph permanently and are switched
    /// with `bypass` rather than rewired, so changing the stage mid-play
    /// cannot glitch the graph.
    func buildMasterChain() { // swiftlint:disable:this inclusive_language
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(softClip)
        engine.attach(limiter)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: softClip, format: nil)
        engine.connect(softClip, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = masterGain
        setMasterOutputStage(masterOutputStage)
    }

    /// Build a brick-wall peak limiter (`kAudioUnitSubType_PeakLimiter`,
    /// Apple). Transparent below full scale, but above it this reduces
    /// gain rather than clipping — see `MasterOutputStage.peakLimiter`
    /// for why that makes it the non-default choice.
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

    /// Test-only read-back of the bypass actually applied to each shaping
    /// node, distinct from the `masterOutputStage` stored mirror.
    var softClipIsBypassed: Bool {
        softClip.bypass
    }

    var limiterIsBypassed: Bool {
        limiter.bypass
    }
}
