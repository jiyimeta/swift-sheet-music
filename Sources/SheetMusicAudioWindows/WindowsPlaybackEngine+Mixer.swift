import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import Synchronization

// The mixer, the master stage, level monitoring and previews. Channel messages go to the score synth under
// `PlaybackCore`'s lock, so they never interleave with the render thread's `reassertChannelState`.

extension WindowsPlaybackEngine {
    // MARK: Mixer

    /// A strip's slider, linear in `0.0...1.0`, sent as CC 7 (the Apple engine's `applyMixerState`).
    public func setVolume(forChannel id: MixerChannel.Kind, to value: Float) {
        let clamped = max(0, min(1, value))
        mutate(channel: id) { $0.volume = clamped }
    }

    public func setMuted(forChannel id: MixerChannel.Kind, to muted: Bool) {
        mutate(channel: id) { $0.isMuted = muted }
    }

    /// Solo is inclusive and the metronome is off the solo bus (`MixerChannel.isSoloable`): soloing it does nothing.
    public func setSoloed(forChannel id: MixerChannel.Kind, to soloed: Bool) {
        mutate(channel: id) { channel in
            guard channel.isSoloable else { return }
            channel.isSoloed = soloed
        }
    }

    /// Swaps an instrument strip's program: on a drum strip, the kit in bank 128. No-op for the metronome.
    public func setProgram(forChannel id: MixerChannel.Kind, to program: UInt8) {
        guard case .instrument = id else { return }
        core.shared.withLock { shared in
            guard let index = shared.mixerChannels.firstIndex(where: { $0.id == id }) else { return }
            shared.mixerChannels[index].program = program
            if let strip = shared.strips.first(where: { $0.kind == id }), let synth = shared.session?.score {
                synth.selectProgram(
                    channel: strip.channel, bank: strip.isDrum ? 128 : strip.bank, program: Int32(min(127, program)),
                )
            }
            shared.applyMixerState()
        }
    }

    private func mutate(channel id: MixerChannel.Kind, _ change: (inout MixerChannel) -> Void) {
        core.shared.withLock { shared in
            guard let index = shared.mixerChannels.firstIndex(where: { $0.id == id }) else { return }
            change(&shared.mixerChannels[index])
            shared.applyMixerState()
        }
    }

    // MARK: Master stage and levels

    /// The master output gain, a linear multiplier on the whole mix (score and metronome). Negative values clamp to
    /// zero; no ceiling — what a boost does past full scale is `setMasterOutputStage(_:)`'s business, as on the Apple
    /// engine. Survives a prepare.
    public func setMasterGain(_ gain: Float) { // swiftlint:disable:this inclusive_language
        core.shared.withLock { $0.outputGain = max(0, gain) }
    }

    /// What shapes a mix the gain pushed past full scale. `.softClip` is the shared `SoftClip` curve.
    public func setMasterOutputStage(_ stage: MasterOutputStage) { // swiftlint:disable:this inclusive_language
        core.shared.withLock { $0.outputStage = stage }
    }

    /// Reports the mix's level once per device callback: post-gain and pre-shaping, peak and RMS over both channels.
    /// `handler` runs on the output thread with the audio waiting on it — hop to the UI, and do not block. Starting
    /// again replaces the handler; it survives a prepare.
    public func startLevelMonitoring(_ handler: @escaping @Sendable (MixLevel) -> Void) {
        core.shared.withLock { $0.levelHandler = handler }
    }

    public func stopLevelMonitoring() {
        core.shared.withLock { $0.levelHandler = nil }
    }

    // MARK: Previews

    /// Briefly sounds the note `noteID` names, on the channel its staff plays at the note's tick (after an instrument
    /// change, the new instrument's). Which preview supersedes which and how long each rings is the shared
    /// `NotePreviewPolicy`'s (a drum rings 2 s); the note-off is timed in rendered frames on the render thread.
    public func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval = 0.3, velocity: UInt8 = 96) {
        guard let loaded, let resolved = AudioMidiBridge.pitchAndStaff(score: score, noteID: noteID) else { return }
        let tick = PreviewRouting.tick(of: noteID, in: score)
        guard let channel = midiChannel(forStaff: resolved.staffIndex, atTick: tick) else { return }
        let isDrum = loaded.derivation.channelLayout.staffIsDrum[resolved.staffIndex] ?? false
        let pitch = UInt8(clamping: resolved.pitch)
        core.shared.withLock { shared in
            guard let synth = shared.session?.score else { return }
            let plan = shared.previewPolicy.begin(
                voice: PreviewVoice(channel: channel, pitch: pitch), velocity: velocity, isDrum: isDrum,
                ringMilliseconds: Int(duration * 1000),
            )
            // The superseded note by its own note-off, as Android does: FluidSynth needs no CC 120 workaround.
            if let previous = plan.supersedes {
                synth.noteOff(channel: Int32(previous.channel), pitch: Int32(previous.pitch))
            }
            synth.noteOn(channel: Int32(channel), pitch: Int32(pitch), velocity: Int32(velocity))
            let ringFrames = Int64((Double(plan.ringMilliseconds) * shared.sampleRate / 1000).rounded())
            shared.previewDeadline = PreviewDeadline(
                generation: plan.generation, frame: shared.renderedFrames + ringFrames,
            )
        }
    }

    /// Starts a held preview on `flatStaffIndex`'s channel at `tick` — sounding until `previewNoteOff(pitch:)` or the
    /// next `previewNoteOn`. Cuts a tap preview still ringing. Meant for while stopped or paused; the caller gates it,
    /// as on the Apple engine. `tick` is the score tick the note sits at: after a mid-score instrument change only the
    /// right tick sounds the new instrument.
    public func previewNoteOn(pitch: UInt8, onStaff flatStaffIndex: Int, velocity: UInt8 = 96, atTick tick: Int) {
        guard let channel = midiChannel(forStaff: flatStaffIndex, atTick: tick) else { return }
        core.shared.withLock { shared in
            guard let synth = shared.session?.score else { return }
            if let tap = shared.previewPolicy.silence() {
                synth.noteOff(channel: Int32(tap.channel), pitch: Int32(tap.pitch))
            }
            shared.previewDeadline = nil
            if let held = shared.sustainedPreview {
                synth.noteOff(channel: Int32(held.channel), pitch: Int32(held.pitch))
            }
            synth.noteOn(channel: Int32(channel), pitch: Int32(pitch), velocity: Int32(velocity))
            shared.sustainedPreview = SustainedPreview(staff: flatStaffIndex, channel: channel, pitch: pitch)
        }
    }

    /// Ends the held preview of `pitch`; no-op unless it is the one held.
    public func previewNoteOff(pitch: UInt8) {
        core.shared.withLock { shared in
            guard let held = shared.sustainedPreview, held.pitch == pitch else { return }
            shared.session?.score.noteOff(channel: Int32(held.channel), pitch: Int32(held.pitch))
            shared.sustainedPreview = nil
        }
    }

    /// The live channel `flatStaffIndex` sounds on at `tick` (`PreviewRouting`, shared with the Apple engine).
    func midiChannel(forStaff flatStaffIndex: Int, atTick tick: Int) -> UInt8? {
        guard let derivation = loaded?.derivation else { return nil }
        return PreviewRouting.channel(
            forStaff: flatStaffIndex, atTick: tick, openingChannels: derivation.channelLayout.staffMIDIChannels,
            switches: derivation.staffChannelSwitches,
        )
    }
}
