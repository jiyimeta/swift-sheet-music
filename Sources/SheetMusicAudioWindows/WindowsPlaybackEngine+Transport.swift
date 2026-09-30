import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI
import Synchronization

// The transport: play (with a count-in), pause, stop, seek, skip, the loop, rate, tuning and transposition. Every
// move happens in the players under `PlaybackCore`'s lock; what has to land on the beat is left to the render thread.

extension WindowsPlaybackEngine {
    // MARK: Transport

    /// Starts playing from `cursor`, or — with none — resumes where playback paused, or starts from the top when
    /// stopped (the Apple engine's `effectiveStartCursor`). A start outside an active loop starts at the loop's start.
    ///
    /// With `countIn`, one bar of the effective meter (plus any anacrusis and mid-bar lead-in — `CountInBeats`) is
    /// counted on the metronome's transport first, audible whatever the metronome's mute says; the score starts on the
    /// render thread when the count is over, so the downbeat lands on the sample clock. A count into an active loop
    /// counts into the loop's start. The count's sequence is the Android engine's: `MetronomeSequenceBuilder` with the
    /// pre-roll clicks in front of the body's, based at the unrolled start tick.
    ///
    /// A `score` other than the prepared one is adopted first, as `replaceScore(with:)` would.
    public func play(from cursor: ScoreCursor? = nil, in score: Score, countIn: Bool = false) {
        guard let current = loaded else { return }
        if score != current.score {
            do {
                try replaceScore(with: PreparedPlayback.make(score: score))
            } catch {
                return
            }
        }
        guard let loaded else { return }
        let timeline = loaded.derivation.timeline
        let unroll = loaded.derivation.unroll
        let (state, currentTick, loop) = core.shared.withLock { ($0.state, $0.reportedScoreTick, $0.transportLoop) }

        // `nil` with a paused (or playing) transport resumes exactly where it is, as the Apple engine's AUMIDISynth
        // path leaves a paused sequencer's beat alone; only a stopped one starts from the top.
        var target = cursor
            .flatMap { timeline.frame(forCursor: $0)?.tick }
            .map { unroll.firstUnrolledTick(forNotated: $0) }
        if target == nil, state == .stopped {
            target = 0
        }
        if let loop {
            let probe = target ?? currentTick
            if probe < loop.startTick || probe >= loop.endTick {
                target = loop.startTick
            }
        }

        if countIn {
            var baseTick = target ?? currentTick
            let notated = unroll.notatedTick(fromUnrolled: baseTick)
            let frame = timeline.frame(atTick: notated)
            if let frame {
                // Count into the frame's onset, in the same pass: the count-in's lead-in is measured to it.
                baseTick -= notated - frame.tick
            }
            if let plan = CountInBeats.compute(score: loaded.score, startCursor: frame?.cursor),
               startCountIn(plan: plan, baseTick: baseTick, loaded: loaded)
            {
                return
            }
        }
        startPlaying(from: target)
    }

    private func startCountIn(plan: CountInBeats.Result, baseTick: Int, loaded: LoadedScore) -> Bool {
        let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
            rendered: loaded.rendered, metronomeBeats: loaded.derivation.metronomeBeats, plan: plan,
            baseTick: baseTick, includingPreRollClicks: true,
        )
        guard let bytes = try? MidiWriter.write(sequence) else { return false }
        return core.shared.withLock { shared -> Bool in
            guard shared.session != nil else { return false }
            shared.stopPlayers(silence: shared.state == .playing ? .release : .untouched)
            guard var session = shared.session,
                  let player = try? PlayerHandle.make(on: session.metronome, midi: bytes, rate: shared.rate)
            else { return false }
            session.countInMetronome?.delete()
            session.countInMetronome = player
            shared.session = session
            // The score waits at its start; the metronome's sequence runs `preRollTicks - baseTick` ahead of it.
            shared.rewind(to: baseTick)
            shared.usingCountInMetronome = true
            shared.metronomeOffsetTicks = plan.preRollTicks - baseTick
            shared.countIn = PlaybackTransportStepper.CountIn(preRollTicks: plan.preRollTicks, scoreStartTick: baseTick)
            player.play()
            shared.state = .playing
            shared.hasCursor = true
            return true
        }
    }

    /// Plays from the unrolled `target`, or resumes in place with none.
    private func startPlaying(from target: Int?) {
        core.shared.withLock { shared in
            guard shared.session != nil else { return }
            var target = target
            let wasPlaying = shared.state == .playing
            if shared.countIn != nil || shared.usingCountInMetronome {
                // Leaving a count-in (or its sequence): the plain metronome, level with the score.
                target = target ?? shared.reportedScoreTick
            }
            if wasPlaying, target == nil {
                return
            }
            if let target {
                shared.stopPlayers(silence: wasPlaying ? .release : .untouched)
                shared.rewind(to: target)
            }
            shared.startPlayers()
            shared.state = .playing
            shared.hasCursor = true
            // The first block carries out the seek above (or the pause's) and its controller chase.
            shared.reassertPending = true
        }
    }

    /// Pauses at the current position; `play(...)` resumes there. The players stop and everything sounding is cut
    /// (the Apple engine's `silenceSoundingVoices`); the stream keeps running, so a preview sounds while paused. A
    /// pause during a count-in keeps the start the count was counting into.
    public func pause() {
        core.shared.withLock { shared in
            if shared.state == .playing {
                let resume = shared.reportedScoreTick
                shared.stopPlayers(silence: .cut)
                shared.rewind(to: resume)
            }
            shared.state = .paused
        }
    }

    /// Stops and rewinds to the start; the cursor clears. Everything sounding is cut.
    public func stop() {
        core.shared.withLock { shared in
            shared.stopPlayers(silence: .cut)
            shared.rewind(to: 0)
            shared.state = .stopped
            shared.hasCursor = false
        }
    }

    /// Moves playback to `cursor` without changing play / pause state, snapped into an active loop — the Apple
    /// engine's click-to-seek. While playing, the jump is carried out between two chunks, with notes off before it and
    /// the channel state reasserted after the player's controller chase. A seek during a count-in ends it and the
    /// score starts at `cursor` at once (the Apple SwiftySynth backend's `seek`).
    public func seek(to cursor: ScoreCursor) {
        guard let loaded, let frame = loaded.derivation.timeline.frame(forCursor: cursor) else { return }
        let tick = loaded.derivation.unroll.firstUnrolledTick(forNotated: snapTickToLoop(frame.tick))
        core.shared.withLock { shared in
            shared.reposition(to: tick)
        }
    }

    /// Seeks to an absolute time in seconds, clamped to `[0, totalTimeSeconds]` — `skip(by:)` from where playback is.
    public func seek(toTimeSeconds seconds: TimeInterval) {
        skip(by: seconds - currentTimeSeconds)
    }

    /// Moves playback by `seconds` (negative: back), clamped to the score, keeping play / pause state: the frame at the
    /// target time, through `seek(to:)` — the Apple engine's injected-backend `skip(by:)`.
    public func skip(by seconds: TimeInterval) {
        guard let loaded else { return }
        let timeline = loaded.derivation.timeline
        let target = max(0, min(timeline.totalSeconds, currentTimeSeconds + seconds))
        guard let frame = timeline.frame(atTime: target) else { return }
        seek(to: frame.cursor)
    }

    // MARK: Loop

    /// Loops the half-open region `[start, end)`: playback wraps at `end`'s onset. No-op when either does not resolve
    /// or `start` is not before `end`.
    public func setLoop(from start: ScoreCursor, to end: ScoreCursor) {
        guard let timeline = loaded?.derivation.timeline,
              let startFrame = timeline.frame(forCursor: start),
              let endFrame = timeline.frame(forCursor: end),
              startFrame.tick < endFrame.tick
        else { return }
        apply(loop: LoopRange(startTick: startFrame.tick, endTick: endFrame.tick))
    }

    /// Loops from `start` through the end of `last`'s notated duration, so the last selected note rings before the
    /// wrap.
    public func setLoop(from start: ScoreCursor, throughEndOf last: ScoreItemID) {
        guard let timeline = loaded?.derivation.timeline,
              let startFrame = timeline.frame(forCursor: start),
              let endTick = timeline.itemEndTicks[last],
              startFrame.tick < endTick
        else { return }
        apply(loop: LoopRange(startTick: startFrame.tick, endTick: endTick))
    }

    /// Stops looping: playback runs on past the old loop's end.
    public func clearLoop() {
        core.shared.withLock { shared in
            shared.loopRange = nil
            shared.transportLoop = nil
        }
    }

    /// Keeps the loop notated (what the host reads back) and its projection onto the unrolled transport, which is
    /// what the render thread compares the player's tick against (`TransportLoop`, shared with the Apple engine).
    private func apply(loop: LoopRange) {
        guard let derivation = loaded?.derivation else { return }
        let projected = TransportLoop.project(
            loop, timeline: derivation.timeline, unroll: derivation.unroll, unrolledTimeMap: derivation.unrolledTimeMap,
        )
        core.shared.withLock { shared in
            shared.loopRange = loop
            shared.transportLoop = projected
        }
    }

    /// Clamps a notated tick into the active loop, as the Apple engine's `snapTickToLoop` does.
    private func snapTickToLoop(_ tick: Int) -> Int {
        guard let loop = loopRange else { return tick }
        return tick < loop.startTick || tick >= loop.endTick ? loop.startTick : tick
    }

    // MARK: Rate, tuning, transposition

    /// Scales playback speed (`1.0` = the score's tempo), on both players, through `fluid_player_set_tempo`'s internal
    /// scale — so the tempo map still applies. Remembered: a player built later (a prepare, a count-in) starts at it.
    /// Not clamped here, as on the Apple engine; FluidSynth ignores a scale outside 0.001…1000.
    public func setRate(_ rate: Float) {
        core.shared.withLock { shared in
            shared.rate = rate
            guard let session = shared.session else { return }
            session.scorePlayer.setTempo(rate)
            session.bodyMetronome.setTempo(rate)
            session.countInMetronome?.setTempo(rate)
        }
    }

    /// Transposes playback by `semitones`, clamped to −12…+12 as on the Apple engine: a tuning shift on every melodic
    /// channel (the MIDI tuning RPN, `MasterTuning`), so notes already sounding move with it and drums stay put.
    /// Survives a prepare.
    public func setTranspose(semitones: Int) {
        let clamped = max(-12, min(12, semitones))
        core.shared.withLock { shared in
            shared.transposeSemitones = clamped
            shared.applyTuning()
        }
    }

    /// Retunes playback to an A4 reference `cents` off 440 Hz — every channel, drums included, as the Apple engine's
    /// percussion unit is (`MasterTuning.effectiveCents`). Survives a prepare.
    public func setMasterTuning(cents: Double) { // swiftlint:disable:this inclusive_language
        core.shared.withLock { shared in
            shared.tuningCents = cents
            shared.applyTuning()
        }
    }
}
