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

    /// Seats a transport recorded before a score swap (`WindowsPlaybackEngine.replaceScore`), right after `install`
    /// in the same critical section: the loop, then the players parked at the seat's tick and started when it was
    /// playing. A playing seat whose cursor no longer resolves plays from the top, as the Apple engine's
    /// `play(from: nil)` does; a paused or stopped one stays stopped at the top.
    mutating func seat(_ seat: WindowsPlaybackEngine.TransportSeat) {
        if let loop = seat.loop {
            loopRange = loop.notated
            transportLoop = loop.projected
        }
        switch seat.state {
        case .playing:
            rewind(to: seat.tick ?? 0)
            startPlayers()
            state = .playing
            hasCursor = true
            reassertPending = true
        case .paused:
            guard let tick = seat.tick else { return }
            rewind(to: tick)
            state = .paused
            hasCursor = true
        case .stopped, .exporting:
            guard let tick = seat.tick else { return }
            rewind(to: tick)
            hasCursor = true
        }
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
        // Previews sounded on the old synth.
        _ = previewPolicy.silenceVoices()
        previewDeadline = nil
        sustainedPreview = nil
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
    ///
    /// A preview lifts the strips past this while the transport is stopped (`applyPreviewChannelState`), and the synth
    /// keeps the lifted CC 7 across its resets, so every start of the transport sends this first.
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

    /// CC 7 on every strip at the level a preview sounds it at (`MixerChannel.previewGain`), before a preview's
    /// note-on: with the transport stopped or paused, the slider whatever the mute and solo say — a part muted, or shut
    /// out by a solo, still sounds the note the user tapped — and playback's own level while the score plays. The
    /// Apple engine's `applyPreviewChannelState`.
    func applyPreviewChannelState() {
        guard let synth = session?.score else { return }
        let soloing = mixerChannels.isSoloing
        let isPlaying = state == .playing
        for strip in strips {
            let gain = mixerChannels.first(where: { $0.id == strip.kind })?
                .previewGain(soloing: soloing, isPlaying: isPlaying) ?? 0
            synth.controlChange(channel: strip.channel, controller: 7, value: Self.controllerVolume(gain))
        }
    }

    /// The Apple engine's CC 7: the linear volume scaled to 0…127 and rounded, 0 while silenced by mute or solo.
    private static func channelVolume(_ channel: MixerChannel?, soloing: Bool) -> Int32 {
        controllerVolume(channel?.playbackGain(soloing: soloing) ?? 0)
    }

    /// A linear gain as CC 7: scaled to 0…127 and rounded.
    private static func controllerVolume(_ gain: Float) -> Int32 {
        Int32(min(127, max(0, (gain * 127).rounded())))
    }

    // MARK: Previews

    /// A preview's note-on on the score synth, sent at once. A score player stopped in the same moment has already cut
    /// its voices inside `stop()` (`HostedSequence.stop`), so nothing it renders later can catch this one — unlike a
    /// FluidSynth player, whose All Sound Off came in its next block and made the engine hold previews back until then.
    func sendPreviewNoteOn(channel: Int32, pitch: Int32, velocity: Int32) {
        session?.score.noteOn(channel: channel, pitch: pitch, velocity: velocity)
    }

    /// A preview's note-off on the score synth.
    func sendPreviewNoteOff(channel: Int32, pitch: Int32) {
        session?.score.noteOff(channel: channel, pitch: pitch)
    }

    /// Forgets every preview, silencing what is sounding: for a stop of the synth it plays on.
    mutating func cancelPreviews() {
        let voices = previewPolicy.silenceVoices()
        previewDeadline = nil
        guard let synth = session?.score else {
            sustainedPreview = nil
            return
        }
        for voice in voices {
            synth.noteOff(channel: Int32(voice.channel), pitch: Int32(voice.pitch))
        }
        if let held = sustainedPreview {
            synth.noteOff(channel: Int32(held.channel), pitch: Int32(held.pitch))
        }
        sustainedPreview = nil
    }
}
