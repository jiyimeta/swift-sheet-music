import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

// The transport moves and channel state `Shared` offers both threads: stopping, parking and starting the players,
// installing a score, reasserting what the mixer owns. Everything here runs under `PlaybackCore.shared`'s lock.

extension Shared {
    /// The score position to report, unrolled: a seek not yet carried out, the start a count-in counts into, or the
    /// player's own tick.
    var reportedScoreTick: Int {
        if let deferredSeek { return deferredSeek.scoreTick }
        if let pendingScoreTick { return pendingScoreTick }
        if let countIn { return countIn.scoreStartTick }
        return session?.scorePlayer.tick ?? 0
    }

    /// What a stop does to the notes sounding. A playing sequence's own stop cuts its synth's voices
    /// (`HostedSequence.stop`); this is about the rest — previews, the click.
    enum SilenceMode {
        /// Nothing: nothing of the transport's was sounding (a play from stopped or paused), and a preview may be.
        case untouched
        /// Note-off everywhere.
        case release
        /// Everything cut at once — a pause or stop by the host, the Apple engine's `silenceSoundingVoices`.
        case cut
    }

    /// Stops every player and leaves any count-in: the metronome maps through its whole body from here on.
    ///
    /// (FluidSynth refused a never-played player every seek past tick 0, and this used to replace such a player with a
    /// fresh one. A SwiftySynth sequence takes any seek, stopped or not.)
    mutating func stopPlayers(silence: SilenceMode) {
        guard let session else { return }
        if session.scorePlayer.isPlaying {
            scoreStopUnrendered = true
        }
        session.scorePlayer.stop()
        session.metronomePlayer.stop()
        scoreRunning = false
        countIn = nil
        metronomeOffsetTicks = session.metronomeWholeBodyOffsetTicks
        deferredSeek = nil
        awaitingWrapLanding = false
        switch silence {
        case .untouched:
            break
        case .release:
            session.score.allNotesOff()
            session.metronome.allNotesOff()
        case .cut:
            session.score.allSoundsOff()
            session.metronome.allSoundsOff()
        }
    }

    /// Parks both stopped players at `tick` (the score's unrolled tick; the metronome at the same beat of its whole
    /// body).
    mutating func rewind(to tick: Int) {
        guard let session else { return }
        session.scorePlayer.seek(to: tick)
        session.metronomePlayer.seek(to: MetronomeSequenceBuilder.metronomeTick(
            forScoreTick: tick, offset: session.metronomeWholeBodyOffsetTicks,
        ))
        metronomeOffsetTicks = session.metronomeWholeBodyOffsetTicks
        pendingScoreTick = tick
    }

    /// Starts the score player and the metronome where they are parked.
    mutating func startPlayers() {
        guard let session else { return }
        session.scorePlayer.play()
        session.metronomePlayer.play()
        scoreRunning = true
    }

    /// `reportedScoreTick` folded into the active loop, as the Apple engine's `currentTimeSeconds` folds its
    /// sequencer's beat: a tick past the loop's end reads as where the wrap puts it.
    var foldedReportedScoreTick: Int {
        let tick = reportedScoreTick
        guard let loop = transportLoop, tick >= loop.endTick, loop.endTick > loop.startTick else { return tick }
        return loop.startTick + (tick - loop.startTick) % (loop.endTick - loop.startTick)
    }

    /// Moves the transport to the unrolled `tick`, keeping play / pause state (`WindowsPlaybackEngine.seek(to:)`).
    mutating func reposition(to tick: Int) {
        guard let session else { return }
        hasCursor = true
        guard state == .playing else {
            rewind(to: tick)
            reassertChannelState()
            return
        }
        if scoreRunning {
            // Carried out by the render thread before its next step (see `DeferredSeek`). A count-in's first pass
            // holds only the beats from its start on, so the metronome lands on its whole body.
            let offset = session.metronomeWholeBodyOffsetTicks
            metronomeOffsetTicks = offset
            deferredSeek = DeferredSeek(
                scoreTick: tick,
                metronomeTick: MetronomeSequenceBuilder.metronomeTick(forScoreTick: tick, offset: offset),
            )
        } else {
            // A seek during a count-in ends it: the score starts at `tick` now.
            stopPlayers(silence: .release)
            rewind(to: tick)
            startPlayers()
        }
        reassertPending = true
    }

    /// Takes up a freshly prepared score: its strips, mixer (unless kept), length; the transport stopped at the top,
    /// the loop cleared.
    mutating func install(_ derivation: PlaybackScoreDerivation, keepingMixer: Bool) {
        strips = derivation.channelLayout.liveChannelPlan.strips.map { strip in
            StripSlot(
                kind: .instrument(partIndex: strip.partIndex, ordinal: strip.ordinal),
                channel: Int32(clamping: strip.liveChannel), isDrum: strip.instrument.useDrumset,
                bank: Int32(clamping: strip.instrument.channel.bank), tuning: [],
            )
        }
        if !keepingMixer {
            mixerChannels = derivation.channelLayout.mixerChannels
        }
        totalTicks = max(derivation.unroll.totalUnrolledTicks, derivation.timeline.totalTicks)
        loopRange = nil
        transportLoop = nil
        state = .stopped
        scoreRunning = false
        countIn = nil
        metronomeOffsetTicks = session?.metronomeWholeBodyOffsetTicks ?? 0
        pendingScoreTick = 0
        deferredSeek = nil
        hasCursor = false
        reassertPending = false
        loopWraps = 0
        lastHandoverLateTicks = nil
        lastWrapDetectedTick = nil
        lastWrapLandingTick = nil
        awaitingWrapLanding = false
    }

    /// Moves the transport onto `new` synths and players (a SoundFont reload), at the same position and in the same
    /// play / pause state. A count-in in progress becomes a plain play from the start it was counting into. The old
    /// session stops rendering with the swap; the caller deletes it.
    mutating func adopt(_ new: Session) {
        let resume = reportedScoreTick
        let wasPlaying = state == .playing
        scoreRunning = false
        countIn = nil
        metronomeOffsetTicks = new.metronomeWholeBodyOffsetTicks
        deferredSeek = nil
        awaitingWrapLanding = false
        // Previews sounded on the old synth, and what is held back was meant for it.
        _ = previewPolicy.silence()
        previewDeadline = nil
        sustainedPreview = nil
        heldPreviewMessages.removeAll(keepingCapacity: true)
        scoreStopUnrendered = false
        session = new
        rewind(to: resume)
        if wasPlaying {
            startPlayers()
        }
        reassertChannelState()
        reassertPending = wasPlaying
    }

    // MARK: Channel state

    /// Bank, program, CC 2, CC 7 and tuning on every strip's channel — the sole authority on them after a load, a seek
    /// or a wrap, as the Apple engine's `reapplyMixerPrograms` + `applyMixerState` are: the SMF's tick-0 program and
    /// CC 7 on these channels are stripped (`MidiSynthPostProcess`). `HostedSynth` keeps what this sends and sends it
    /// again after every reset of its own (play, seek, stop). Allocates nothing — a program sent again starts no
    /// prefetch (`HostedSynth.programSelect`) — so it may run on the render thread.
    func reassertChannelState() {
        guard let synth = session?.score else { return }
        let soloing = mixerChannels.isSoloing
        for strip in strips {
            synth.setDrumChannel(strip.channel, isDrum: strip.isDrum)
            let mixer = mixerChannels.first(where: { $0.id == strip.kind })
            if let program = mixer?.program {
                synth.selectProgram(
                    channel: strip.channel, bank: strip.isDrum ? 128 : strip.bank, program: Int32(min(127, program)),
                )
            }
            if !strip.isDrum {
                // MuseScore's expressive banks gate their volume on the breath controller, and nothing streams it:
                // fully open, as Android's `FluidSynthEngine.setupStaves` has it.
                synth.controlChange(channel: strip.channel, controller: 2, value: 127)
            }
            let volume = Self.channelVolume(mixer, soloing: soloing)
            synth.controlChange(channel: strip.channel, controller: 7, value: volume)
            synth.send(strip.tuning, onChannel: strip.channel)
        }
    }

    /// CC 7 on every strip plus the metronome's level: the mixer's volume / mute / solo, as the Apple engine's
    /// `applyMixerState` sends them.
    mutating func applyMixerState() {
        let soloing = mixerChannels.isSoloing
        if let synth = session?.score {
            for strip in strips {
                let volume = Self.channelVolume(mixerChannels.first(where: { $0.id == strip.kind }), soloing: soloing)
                synth.controlChange(channel: strip.channel, controller: 7, value: volume)
            }
        }
        if let click = mixerChannels.first(where: { $0.id == .metronome }) {
            metronomeMuted = click.isMuted
            metronomeVolume = click.volume
        }
    }

    /// Recomputes every strip's tuning burst for the current tuning and transposition and sends it.
    mutating func applyTuning() {
        for index in strips.indices {
            let cents = MasterTuning.effectiveCents(
                tuning: tuningCents, transposeSemitones: transposeSemitones, isPercussion: strips[index].isDrum,
            )
            strips[index].tuning = MasterTuning.rpnControlChanges(cents: cents)
        }
        guard let synth = session?.score else { return }
        for strip in strips {
            synth.send(strip.tuning, onChannel: strip.channel)
        }
    }

    /// The Apple engine's CC 7: the linear volume scaled to 0…127 and rounded, 0 while silenced by mute or solo.
    private static func channelVolume(_ channel: MixerChannel?, soloing: Bool) -> Int32 {
        guard let channel, !channel.isSilenced(soloing: soloing) else { return 0 }
        return Int32(min(127, max(0, (channel.volume * 127).rounded())))
    }

    // MARK: Previews

    /// A preview's note-on on the score synth, or held back while a stopped score player's block is still to come
    /// (`scoreStopUnrendered`).
    mutating func sendPreviewNoteOn(channel: Int32, pitch: Int32, velocity: Int32) {
        if scoreStopUnrendered {
            heldPreviewMessages.append(.noteOn(channel: channel, pitch: pitch, velocity: velocity))
        } else {
            session?.score.noteOn(channel: channel, pitch: pitch, velocity: velocity)
        }
    }

    /// A preview's note-off, held back with the note-ons so the two keep their order.
    mutating func sendPreviewNoteOff(channel: Int32, pitch: Int32) {
        if scoreStopUnrendered {
            heldPreviewMessages.append(.noteOff(channel: channel, pitch: pitch))
        } else {
            session?.score.noteOff(channel: channel, pitch: pitch)
        }
    }

    /// Sends what the previews held back, now that the stopped player's block is rendered. Render thread; allocates
    /// nothing.
    mutating func releaseHeldPreviews(to synth: SynthHandle) {
        scoreStopUnrendered = false
        for message in heldPreviewMessages {
            switch message {
            case let .noteOn(channel, pitch, velocity):
                synth.noteOn(channel: channel, pitch: pitch, velocity: velocity)
            case let .noteOff(channel, pitch):
                synth.noteOff(channel: channel, pitch: pitch)
            }
        }
        heldPreviewMessages.removeAll(keepingCapacity: true)
    }

    /// Forgets every preview, silencing what is sounding: for a stop of the synth it plays on.
    mutating func cancelPreviews() {
        // Never sent, so nothing of them sounds. Every caller deletes the stopped players next, so no All Sound Off
        // is coming to wait for either.
        heldPreviewMessages.removeAll(keepingCapacity: true)
        scoreStopUnrendered = false
        let voice = previewPolicy.silence()
        previewDeadline = nil
        guard let synth = session?.score else {
            sustainedPreview = nil
            return
        }
        if let voice {
            synth.noteOff(channel: Int32(voice.channel), pitch: Int32(voice.pitch))
        }
        if let held = sustainedPreview {
            synth.noteOff(channel: Int32(held.channel), pitch: Int32(held.pitch))
        }
        sustainedPreview = nil
    }
}
