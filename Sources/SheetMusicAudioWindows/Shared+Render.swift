import Foundation
import SheetMusicAudioCore

// The render thread's half of `Shared`: one device callback cut into 64-frame chunks, the transport decisions taken
// between them (`PlaybackTransportStepper`), the preview deadlines, and the output stage. Everything here runs under
// `PlaybackCore.shared`'s lock, on the output thread.

extension Shared {
    mutating func render(
        into buffer: UnsafeMutablePointer<Float>, frames: Int, scratch: UnsafeMutablePointer<Float>,
    ) -> RenderOutcome {
        var outcome = RenderOutcome()
        guard let session else {
            buffer.update(repeating: 0, count: frames * 2)
            return outcome
        }
        let chunk = PlaybackCore.chunkFrames
        var offset = 0
        while offset + chunk <= frames {
            renderChunk(session: session, into: buffer + offset * 2, scratch: scratch, outcome: &outcome)
            offset += chunk
        }
        if offset < frames {
            (buffer + offset * 2).update(repeating: 0, count: (frames - offset) * 2)
        }
        applyOutputStage(to: buffer, frames: frames, outcome: &outcome)
        return outcome
    }

    /// One `chunkFrames` block: both synths, the metronome summed in, then everything decided between blocks.
    private mutating func renderChunk(
        session: Session, into out: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>,
        outcome: inout RenderOutcome,
    ) {
        let chunk = PlaybackCore.chunkFrames
        session.score.write(frames: Int32(chunk), into: out)
        if scoreStopUnrendered {
            // A stopped player's All Sound Off went out at the start of that block; the previews can sound now, from
            // the next one.
            releaseHeldPreviews(to: session.score)
        }
        // Rendered even while silent, so the click transport keeps in step with the score's (the Apple backend keeps
        // its muted metronome transport running for the same reason: an unmute lands on the beat).
        session.metronome.write(frames: Int32(chunk), into: scratch)
        let clickLevel = metronomeLevel
        if clickLevel > 0 {
            for index in 0 ..< chunk * 2 {
                out[index] += scratch[index] * clickLevel
            }
        }
        renderedFrames += Int64(chunk)

        if state == .playing {
            // The block just rendered carried out any seek the running score player had been asked for.
            if scoreRunning {
                pendingScoreTick = nil
                if awaitingWrapLanding {
                    awaitingWrapLanding = false
                    lastWrapLandingTick = session.scorePlayer.tick
                }
                // The probe's trace, when one is recording (the tick is not read otherwise).
                clockTrace?.record(renderedFrames: renderedFrames, tick: session.scorePlayer.tick)
            }
            if let deferred = deferredSeek {
                deferredSeek = nil
                performDeferredSeek(deferred, session: session)
            } else {
                step(session: session, outcome: &outcome)
            }
            if reassertPending, scoreRunning, pendingScoreTick == nil {
                reassertPending = false
                reassertChannelState()
            }
        }

        if let deadline = previewDeadline, renderedFrames >= deadline.frame {
            previewDeadline = nil
            if let voice = previewPolicy.end(generation: deadline.generation) {
                // A note-off, as Android ends its previews: FluidSynth needs none of the CC 120 workarounds the
                // AUMIDISynth path has, and the release rings out on a stream that never parks.
                sendPreviewNoteOff(channel: Int32(voice.channel), pitch: Int32(voice.pitch))
            }
        }
    }

    /// The metronome's level in the mix: its strip's volume, or nothing while its strip is muted — except during a
    /// count-in, which sounds whatever the metronome toggle says (the Apple engine's always-on pre-roll track).
    var metronomeLevel: Float {
        countIn != nil || !metronomeMuted ? metronomeVolume : 0
    }

    private var activeMetronome: PlayerHandle? {
        guard let session else { return nil }
        return usingCountInMetronome ? session.countInMetronome ?? session.bodyMetronome : session.bodyMetronome
    }

    /// Asks `PlaybackTransportStepper` what the positions call for and does it.
    private mutating func step(session: Session, outcome: inout RenderOutcome) {
        var scoreTick = pendingScoreTick ?? session.scorePlayer.tick
        // A player that has sent its sequence's last event stops advancing: to the stepper that is the end (a loop
        // reaching that far still wraps first).
        if scoreRunning, pendingScoreTick == nil, session.scorePlayer.isDone {
            scoreTick = max(scoreTick, totalTicks)
        }
        var metronomeTick = activeMetronome?.tick ?? 0
        // A count-in sequence can end before its bars do — its last event is a click's note-off when no body beat
        // follows the start position — and a player that has run out stops advancing: it counts as having got there.
        if let countIn, activeMetronome?.isDone == true {
            metronomeTick = max(metronomeTick, countIn.preRollTicks)
        }
        let actions = PlaybackTransportStepper.step(PlaybackTransportStepper.Snapshot(
            isPlaying: true, scoreTick: scoreTick, metronomeTick: metronomeTick,
            metronomeOffsetTicks: metronomeOffsetTicks, loop: transportLoop, countIn: countIn, totalTicks: totalTicks,
        ))
        let positions = (score: scoreTick, metronome: metronomeTick)
        for action in actions {
            perform(action, session: session, at: positions, outcome: &outcome)
        }
    }

    private mutating func perform(
        _ action: PlaybackTransportStepper.Action, session: Session, at positions: (score: Int, metronome: Int),
        outcome: inout RenderOutcome,
    ) {
        let scoreTickAtStep = positions.score
        let metronomeTick = positions.metronome
        switch action {
        case .allNotesOff:
            session.score.allNotesOff()
            session.metronome.allNotesOff()
        case let .seekScore(tick):
            session.scorePlayer.seek(to: tick)
            // A player that ran off the end of its sequence ignores a seek until played again.
            if !session.scorePlayer.isPlaying {
                session.scorePlayer.play()
            }
            pendingScoreTick = tick
            reassertPending = true
        case let .seekMetronome(tick):
            if usingCountInMetronome {
                // The count is over once its first pass is: the jump lands on the plain sequence, which has every
                // beat (the count-in's keeps only those from its start position on) — the Apple backend's loop wrap.
                session.countInMetronome?.stop()
                usingCountInMetronome = false
                let bodyTick = tick - metronomeOffsetTicks
                metronomeOffsetTicks = 0
                session.bodyMetronome.seek(to: bodyTick)
                session.bodyMetronome.play()
            } else {
                session.bodyMetronome.seek(to: tick)
                if !session.bodyMetronome.isPlaying {
                    // The click sequence ends one tick after its last beat, before the score does.
                    session.bodyMetronome.play()
                }
            }
        case let .startScore(tick):
            session.scorePlayer.seek(to: tick)
            session.scorePlayer.play()
            scoreRunning = true
            pendingScoreTick = tick
            reassertPending = true
            if let countIn {
                lastHandoverLateTicks = metronomeTick - countIn.preRollTicks
            }
            countIn = nil
        case .wrapped:
            loopWraps += 1
            lastWrapDetectedTick = scoreTickAtStep
            awaitingWrapLanding = true
        case .stopAtEnd:
            // The Apple engine's end-of-score `stop()`, rewinding to the top. The stepper already sent notes-off.
            stopPlayers(silence: .release)
            rewind(to: 0)
            state = .stopped
            hasCursor = false
            outcome.reachedEnd = true
            outcome.onEvent = onEvent
        }
    }

    private mutating func performDeferredSeek(_ seek: DeferredSeek, session: Session) {
        session.score.allNotesOff()
        session.metronome.allNotesOff()
        session.scorePlayer.seek(to: seek.scoreTick)
        if !session.scorePlayer.isPlaying {
            session.scorePlayer.play()
        }
        if let metronome = activeMetronome {
            metronome.seek(to: seek.metronomeTick)
            if !metronome.isPlaying {
                metronome.play()
            }
        }
        pendingScoreTick = seek.scoreTick
        reassertPending = true
    }

    /// Master gain, then the level reading (post-gain, pre-shaping — what the output stage is being asked to deal
    /// with, Android's rule), then the soft clip when chosen.
    private mutating func applyOutputStage(
        to buffer: UnsafeMutablePointer<Float>, frames: Int, outcome: inout RenderOutcome,
    ) {
        let gain = outputGain
        let clips = outputStage == .softClip
        let handler = levelHandler
        guard gain != 1 || clips || handler != nil else { return }
        let count = frames * 2
        var peak: Float = 0
        var sumSquares: Double = 0
        var outputPeak: Float = 0
        for index in 0 ..< count {
            var sample = buffer[index] * gain
            if handler != nil {
                peak = max(peak, abs(sample))
                sumSquares += Double(sample) * Double(sample)
            }
            if clips {
                sample = SoftClip.apply(sample)
            }
            outputPeak = max(outputPeak, abs(sample))
            buffer[index] = sample
        }
        lastOutputPeak = outputPeak
        if let handler, count > 0 {
            // Both channels pooled by mean square before the root, as the Apple engine's tap does.
            outcome.level = MixLevel(peak: peak, rms: Float((sumSquares / Double(count)).squareRoot()))
            outcome.levelHandler = handler
        }
    }
}
