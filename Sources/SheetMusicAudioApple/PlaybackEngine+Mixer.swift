import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

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

    /// Swap the GM program (sound) on an instrument strip. No-op for
    /// the metronome, whose patch is fixed (Hi/Low Wood Block on
    /// the percussion bank).
    public func setProgram(
        forChannel id: MixerChannel.Kind, to program: UInt8,
    ) {
        guard case .instrument = id else { return }
        loadProgram(forChannel: id, program: program)
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

    /// Rebuild the channel array from `score`'s LIVE channel plan — one
    /// strip per (part × distinct instrument), plus the metronome.
    /// Existing volume / mute / solo state is dropped — a new score is
    /// a new mix. Called from `prepare(score:)`. Initial slider values
    /// come from MSCX `<controller ctrl="7" value="N"/>`, stored on
    /// each strip's `InstrumentChannel.volume` (0...127). MuseScore's
    /// default is 100/127.
    func rebuildMixerChannels(for score: Score) {
        let plan = LiveChannelPlan.build(score: score)
        var channels: [MixerChannel] = []
        channels.reserveCapacity(plan.strips.count + 1)
        for strip in plan.strips {
            channels.append(MixerChannel(
                id: .instrument(
                    partIndex: strip.partIndex, ordinal: strip.ordinal,
                ),
                name: stripName(for: strip, in: score),
                volume: Float(max(0, min(127, strip.instrument.channel.volume))) / 127,
                program: strip.instrument.useDrumset
                    ? nil
                    : UInt8(clamping: strip.instrument.channel.program),
            ))
        }
        channels.append(MixerChannel(
            id: .metronome,
            name: "Metronome",
        ))
        replaceMixerChannels(channels)
    }

    /// "S (Piano)" / "S (Accordion)" — the part's display name plus the
    /// instrument, so a part with instrument changes reads unambiguously.
    /// A part with a single instrument keeps the bare part name.
    /// Instrument name falls back longName → trackName → id.
    private func stripName(
        for strip: LiveChannelPlan.Strip, in score: Score,
    ) -> String {
        let address = StaffAddress(
            partIndex: strip.partIndex, staffIndexInPart: 0,
        )
        let partName = score.staffDisplayName(at: address)
        let instrumentName = strip.instrument.longName
            ?? strip.instrument.trackName
            ?? strip.instrument.id
        let distinct = score.instrumentTimeline(forPart: strip.partIndex).count
        guard distinct > 1, !instrumentName.isEmpty else { return partName }
        return "\(partName) (\(instrumentName))"
    }

    /// Push the current mixer state into the live audio graph. Mute /
    /// volume are sent as CC 7 (Channel Volume) on each strip's
    /// renderer-assigned MIDI channel of its owning synth unit (melodic
    /// or percussion, depending on the instrument). This is the *sole*
    /// authority on those channels' volume: the SMF's competing tick-0
    /// CC 7 is stripped for mixer-managed channels in
    /// `PlaybackEngine.postProcessForMIDISynth`, so a seek / loop-wrap
    /// rewind can no longer chase-fire it and clobber the user's choice.
    ///
    /// Solo overrides everything else — when any channel is soloed,
    /// non-soloed channels go silent.
    func applyMixerState() {
        let anySoloed = mixerChannels.contains(where: \.isSoloed)
        for channel in mixerChannels {
            let effectivelyMuted = channel.isMuted
                || (anySoloed && !channel.isSoloed)
            let gain: Float = effectivelyMuted ? 0 : channel.volume
            switch channel.id {
            case .instrument:
                applyInstrumentGain(forChannel: channel.id, gain: gain)
            case .metronome:
                setMetronomeEnabled(!effectivelyMuted)
                setMetronomeVolume(channel.volume)
            }
        }
    }

    /// Re-assert EVERY mixer-managed instrument channel's program +
    /// volume on the injected backend synth, for use immediately before
    /// a tap / hold preview's note-on. Playback streams the SMF's
    /// programChange plus the mixer's CC 7 through the sequencer, but a
    /// preview drives the synth directly — and a prior playback's
    /// sequencer resets EVERY channel back to GM defaults, so without
    /// this a post-playback audition on any strip other than the one
    /// last played would sound on program 0 (piano) at the default
    /// volume: with every program living at tick 0 in the rendered SMF,
    /// re-asserting only the about-to-sound channel would leave every
    /// OTHER deduped instrument channel silently stuck at those
    /// defaults. No-op unless a backend is injected (the AU path
    /// resolves per-staff instruments itself and needs no direct
    /// re-assert).
    func reassertBackendChannelState() {
        guard let backend else { return }
        let anySoloed = mixerChannels.contains(where: \.isSoloed)
        for channel in mixerChannels {
            guard case .instrument = channel.id,
                  let midiCh = midiChannel(forChannel: channel.id)
            else { continue }
            if let program = channel.program, midiCh != 9 {
                backend.setProgram(channel: midiCh, program: program)
            }
            let effectivelyMuted = channel.isMuted
                || (anySoloed && !channel.isSoloed)
            let gain: Float = effectivelyMuted ? 0 : channel.volume
            backend.sendVolume(
                channel: midiCh, cc7: UInt8(clamping: Int((gain * 127).rounded())),
            )
        }
    }

    private func applyInstrumentGain(forChannel id: MixerChannel.Kind, gain: Float) {
        guard let midiCh = midiChannel(forChannel: id) else { return }
        let cc7 = UInt8(clamping: Int((gain * 127).rounded()))
        if let backend {
            backend.sendVolume(channel: midiCh, cc7: cc7)
            return
        }
        let unit = midiCh == 9 ? percussionSynth : melodicSynth
        guard let unit else { return }
        MIDISynthBuilder.sendControlChange(
            into: unit, controller: 7, value: cc7, onChannel: midiCh,
        )
    }
}
