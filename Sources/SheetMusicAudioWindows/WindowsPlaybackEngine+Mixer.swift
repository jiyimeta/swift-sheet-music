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

    /// Briefly sounds the note `noteID` names. See `playPreview(noteIDs:in:duration:velocity:)`.
    public func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval = 0.3, velocity: UInt8 = 96) {
        playPreview(noteIDs: [noteID], in: score, duration: duration, velocity: velocity)
    }

    /// Briefly sounds the notes `noteIDs` name, struck together, each on the channel its staff plays at the note's
    /// tick (after an instrument change, the new instrument's) — what the host sounds for a tap on the score, the
    /// Apple engine's `playPreview(noteIDs:)`. A tap on a beat passes everything that starts there
    /// (`Score.onsetNoteIDs(of:)`): a chord's every key, and a second voice's notes with the first's, so the kick of a
    /// drum part written in two voices sounds with the cymbal above it.
    ///
    /// The notes are one audition (`NotePreviewPolicy.begin(voices:)`): the next preview cuts all of them, and they
    /// ring for one length — a drum's 2 s when any of them is a drum. The note-offs are timed in rendered frames on
    /// the render thread. A note that does not resolve is skipped; when none does, nothing sounds and whatever is
    /// ringing is left alone.
    public func playPreview(
        noteIDs: [NoteID], in score: Score, duration: TimeInterval = 0.3, velocity: UInt8 = 96,
    ) {
        guard let loaded else { return }
        var voices: [PreviewVoice] = []
        var isDrum = false
        for noteID in noteIDs {
            guard let resolved = AudioMidiBridge.pitchAndStaff(score: score, noteID: noteID),
                  let channel = midiChannel(
                      forStaff: resolved.staffIndex, atTick: PreviewRouting.tick(of: noteID, in: score),
                  )
            else { continue }
            voices.append(PreviewVoice(channel: channel, pitch: UInt8(clamping: resolved.pitch)))
            isDrum = isDrum || (loaded.derivation.channelLayout.staffIsDrum[resolved.staffIndex] ?? false)
        }
        core.shared.withLock { shared in
            guard shared.session != nil,
                  let plan = shared.previewPolicy.begin(
                      voices: voices, velocity: velocity, isDrum: isDrum, ringMilliseconds: Int(duration * 1000),
                  )
            else { return }
            // The superseded notes by their own note-offs, as Android does: the synth needs no CC 120 workaround.
            for previous in plan.supersededVoices {
                shared.sendPreviewNoteOff(channel: Int32(previous.channel), pitch: Int32(previous.pitch))
            }
            // A muted or solo-shut part still sounds the tapped note.
            shared.applyPreviewChannelState()
            for voice in plan.voices {
                shared.sendPreviewNoteOn(
                    channel: Int32(voice.channel), pitch: Int32(voice.pitch), velocity: Int32(velocity),
                )
            }
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
            guard shared.session != nil else { return }
            for tap in shared.previewPolicy.silenceVoices() {
                shared.sendPreviewNoteOff(channel: Int32(tap.channel), pitch: Int32(tap.pitch))
            }
            shared.previewDeadline = nil
            if let held = shared.sustainedPreview {
                shared.sendPreviewNoteOff(channel: Int32(held.channel), pitch: Int32(held.pitch))
            }
            shared.applyPreviewChannelState()
            shared.sendPreviewNoteOn(channel: Int32(channel), pitch: Int32(pitch), velocity: Int32(velocity))
            shared.sustainedPreview = SustainedPreview(staff: flatStaffIndex, channel: channel, pitch: pitch)
        }
    }

    /// Ends the held preview of `pitch`; no-op unless it is the one held.
    public func previewNoteOff(pitch: UInt8) {
        core.shared.withLock { shared in
            guard let held = shared.sustainedPreview, held.pitch == pitch else { return }
            shared.sendPreviewNoteOff(channel: Int32(held.channel), pitch: Int32(held.pitch))
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
