import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore

extension PlaybackEngine {
    /// Set a channel's slider value. Linear gain in `0.0...1.0`.
    public func setVolume(forChannel id: MixerChannel.Kind, to value: Float) {
        let clamped = max(0, min(1, value))
        mutate(channel: id) { $0.volume = clamped }
    }

    /// Set a channel's mute button state.
    public func setMuted(forChannel id: MixerChannel.Kind, to muted: Bool) {
        mutate(channel: id) { $0.isMuted = muted }
    }

    /// Set a channel's solo button state. Multiple channels can solo
    /// simultaneously; non-soloed channels are silenced whenever any
    /// channel is soloed.
    public func setSoloed(forChannel id: MixerChannel.Kind, to soloed: Bool) {
        mutate(channel: id) { $0.isSoloed = soloed }
    }

    /// Swap the GM program (sound) on a staff channel. No-op for
    /// the metronome, whose patch is fixed (Hi/Low Wood Block on
    /// the percussion bank).
    public func setProgram(
        forChannel id: MixerChannel.Kind, to program: UInt8,
    ) {
        guard case let .staff(idx) = id else { return }
        loadProgram(forStaff: idx, program: program)
        mutate(channel: id) { $0.program = program }
    }

    private func mutate(
        channel id: MixerChannel.Kind,
        _ change: (inout MixerChannel) -> Void,
    ) {
        guard let idx = mixerChannels.firstIndex(where: { $0.id == id })
        else { return }
        mutateMixerChannel(at: idx, change)
        applyMixerState()
    }

    /// Rebuild the channel array from `score`'s parts. Existing
    /// volume / mute / solo state is dropped — a new score is a
    /// new mix. Called from `prepare(score:)`. Initial slider
    /// values come from MSCX `<controller ctrl="7" value="N"/>`,
    /// stored on each part's first `InstrumentChannel.volume`
    /// (0...127). MuseScore's default is 100/127.
    func rebuildMixerChannels(for score: Score) {
        var channels: [MixerChannel] = []
        channels.reserveCapacity(score.totalStaffCount + 1)
        for (idx, entry) in score.allStaves.enumerated() {
            channels.append(MixerChannel(
                id: .staff(idx),
                name: staffName(at: entry.address, in: score),
                volume: initialStaffVolume(at: entry.address, in: score),
                program: initialStaffProgram(at: entry.address, in: score),
            ))
        }
        channels.append(MixerChannel(
            id: .metronome,
            name: "Metronome",
        ))
        replaceMixerChannels(channels)
    }

    /// CC7 (Channel Volume) from the part's first channel, mapped
    /// from MIDI's 0...127 range to the mixer's 0...1. Falls back
    /// to MuseScore's default of 100/127 ≈ 0.787 when the part is
    /// missing or has no channel.
    private func initialStaffVolume(
        at address: StaffAddress, in score: Score,
    ) -> Float {
        let cc7: Int = score.part(at: address)?.instrument.channel.volume ?? 100
        return Float(max(0, min(127, cc7))) / 127
    }

    /// GM program from the part's first channel — what the score's
    /// `<program value="…"/>` chose. Returns nil for drum-kit parts
    /// (`useDrumset == true`): drums play on MIDI channel 10 where
    /// the program byte is ignored, so showing a GM-program picker
    /// for them would advertise a misleading patch name. Also nil
    /// when the part is missing entirely.
    private func initialStaffProgram(
        at address: StaffAddress, in score: Score,
    ) -> UInt8? {
        guard let part = score.part(at: address) else { return nil }
        if part.instrument.useDrumset { return nil }
        return UInt8(clamping: part.instrument.channel.program)
    }

    /// Push the current mixer state into the live audio graph:
    /// per-staff sampler volumes and the metronome
    /// enable/volume. Solo overrides everything else — when any
    /// channel is soloed, non-soloed channels go silent.
    func applyMixerState() {
        let anySoloed = mixerChannels.contains(where: \.isSoloed)
        for channel in mixerChannels {
            let effectivelyMuted = channel.isMuted
                || (anySoloed && !channel.isSoloed)
            let gain: Float = effectivelyMuted ? 0 : channel.volume
            switch channel.id {
            case let .staff(i):
                staffSampler(at: i)?.volume = gain
            case .metronome:
                setMetronomeEnabled(!effectivelyMuted)
                setMetronomeVolume(channel.volume)
            }
        }
    }

    /// Best-effort staff label: prefers the part's track name, then
    /// the instrument long name, falling back to "Staff N".
    private func staffName(at address: StaffAddress, in score: Score) -> String {
        if let part = score.part(at: address) {
            if let n = part.trackName, !n.isEmpty { return n }
            if let n = part.instrument.longName, !n.isEmpty {
                return n
            }
        }
        let flatIdx = score.allStaves.firstIndex(where: { $0.address == address }) ?? 0
        return "Staff \(flatIdx + 1)"
    }
}
