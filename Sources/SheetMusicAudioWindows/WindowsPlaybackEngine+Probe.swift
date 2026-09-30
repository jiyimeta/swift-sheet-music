import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import Synchronization

// Read-backs for `windows-playback-probe`, which checks what the engine asked FluidSynth for against what FluidSynth
// holds, and times the transport against the wall clock. Not API: everything here is `@_spi(PlaybackProbe)`, and a
// host has no business depending on it.

extension WindowsPlaybackEngine {
    /// One mixer strip's live channel.
    @_spi(PlaybackProbe)
    public struct ProbeStrip: Sendable, Equatable {
        public let kind: MixerChannel.Kind
        public let channel: Int
        public let isDrum: Bool
    }

    /// The transport's inner state. Ticks are the unrolled ones the players run on.
    @_spi(PlaybackProbe)
    public struct ProbeTransport: Sendable, Equatable {
        /// The score player's own tick, which trails a seek until the next rendered block carries it out.
        public let scorePlayerTick: Int
        /// What the engine reports instead while a seek is pending.
        public let reportedScoreTick: Int
        /// The metronome player that is playing: its own tick, in its own sequence (ahead of the score's by
        /// `metronomeOffsetTicks` after a count-in).
        public let metronomeTick: Int
        public let metronomeOffsetTicks: Int
        /// The metronome's level in the mix now: 0 while muted, except during a count-in.
        public let metronomeLevel: Float
        public let countingIn: Bool
        public let scoreRunning: Bool
        public let renderedFrames: Int64
        public let loopStartTick: Int?
        public let loopEndTick: Int?
        /// The score tick the last loop wrap was decided at.
        public let lastWrapDetectedTick: Int?
        /// The score player's tick once it had carried out the last wrap's jump.
        public let lastWrapLandingTick: Int?
        /// The largest sample leaving the output stage in the last callback that ran it (post-shaping).
        public let lastOutputPeak: Float
    }

    @_spi(PlaybackProbe)
    public var probeStrips: [ProbeStrip] {
        core.shared.withLock { shared in
            shared.strips.map { ProbeStrip(kind: $0.kind, channel: Int($0.channel), isDrum: $0.isDrum) }
        }
    }

    @_spi(PlaybackProbe)
    public var probeTransport: ProbeTransport? {
        core.shared.withLock { shared -> ProbeTransport? in
            guard let session = shared.session else { return nil }
            let metronome = shared.usingCountInMetronome
                ? session.countInMetronome ?? session.bodyMetronome
                : session.bodyMetronome
            return ProbeTransport(
                scorePlayerTick: session.scorePlayer.tick, reportedScoreTick: shared.reportedScoreTick,
                metronomeTick: metronome.tick, metronomeOffsetTicks: shared.metronomeOffsetTicks,
                metronomeLevel: shared.metronomeLevel, countingIn: shared.countIn != nil,
                scoreRunning: shared.scoreRunning, renderedFrames: shared.renderedFrames,
                loopStartTick: shared.transportLoop?.startTick, loopEndTick: shared.transportLoop?.endTick,
                lastWrapDetectedTick: shared.lastWrapDetectedTick, lastWrapLandingTick: shared.lastWrapLandingTick,
                lastOutputPeak: shared.lastOutputPeak,
            )
        }
    }

    /// Controller `controller` on the score synth's `channel`, as FluidSynth holds it.
    @_spi(PlaybackProbe)
    public func probeController(_ controller: Int, onChannel channel: Int) -> Int? {
        core.shared.withLock { $0.session?.score.controller(Int32(controller), onChannel: Int32(channel)) }
    }

    /// `[bank, program]` on the score synth's `channel`, as FluidSynth holds them.
    @_spi(PlaybackProbe)
    public func probeProgram(onChannel channel: Int) -> [Int]? {
        core.shared.withLock { shared -> [Int]? in
            guard let program = shared.session?.score.program(onChannel: Int32(channel)) else { return nil }
            return [program.bank, program.program]
        }
    }

    /// `[coarse semitones, fine cents]` on the score synth's `channel`, as the tuning RPN left them.
    @_spi(PlaybackProbe)
    public func probeTuning(onChannel channel: Int) -> [Double]? {
        core.shared.withLock { shared -> [Double]? in
            guard let tuning = shared.session?.score.tuning(onChannel: Int32(channel)) else { return nil }
            return [tuning.coarse, tuning.fine]
        }
    }

    /// `[score, metronome]`: voices sounding on each synth.
    @_spi(PlaybackProbe)
    public var probeActiveVoices: [Int] {
        core.shared.withLock { shared in
            guard let session = shared.session else { return [0, 0] }
            return [session.score.activeVoiceCount, session.metronome.activeVoiceCount]
        }
    }

    /// An integer FluidSynth setting of the score synth (`synth.dynamic-sample-loading`, `player.reset-synth`, …).
    @_spi(PlaybackProbe)
    public func probeSetting(_ name: String) -> Int? {
        core.shared.withLock { $0.session?.score.integerSetting(name) }
    }

    /// The unrolled tick a play or seek to `cursor` lands on: its first occurrence in playback order.
    @_spi(PlaybackProbe)
    public func probeUnrolledTick(for cursor: ScoreCursor) -> Int? {
        guard let derivation = loadedDerivation,
              let frame = derivation.timeline.frame(forCursor: cursor)
        else { return nil }
        return derivation.unroll.firstUnrolledTick(forNotated: frame.tick)
    }

    /// How many ticks the score player moves in one 64-frame chunk at the unrolled `tick`, at the current rate.
    @_spi(PlaybackProbe)
    public func probeTicksPerChunk(atUnrolledTick tick: Int) -> Double? {
        guard let derivation = loadedDerivation else { return nil }
        let (rate, sampleRate) = core.shared.withLock { ($0.rate, $0.sampleRate) }
        let timeline = derivation.timeline
        let notated = Double(derivation.unroll.notatedTick(fromUnrolled: tick))
        let secondsPerTick = timeline.seconds(atTick: notated + 1) - timeline.seconds(atTick: notated)
        guard secondsPerTick > 0 else { return nil }
        return Double(PlaybackCore.chunkFrames) / sampleRate / secondsPerTick * Double(rate)
    }

    /// Seconds into the score, continuous between frames — `currentTimeSecondsContinuous`.
    @_spi(PlaybackProbe)
    public var probeContinuousSeconds: TimeInterval {
        currentTimeSecondsContinuous
    }

    /// Makes the output's next buffer request fail with `AUDCLNT_E_DEVICE_INVALIDATED` once, as a device change
    /// would. Inert unless the process runs with `SSM_WASAPI_FAIL_ONCE=invalidated`.
    @_spi(PlaybackProbe)
    public func probeInjectDeviceFault() {
        output?.requestFault()
    }
}
