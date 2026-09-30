/// The decisions a render thread makes between two audio chunks — the count-in's handover to the score, the loop's
/// wrap, the end of the score — as a pure function of where the players are.
///
/// An engine that schedules with sequencer players on the audio thread (the Windows engine: FluidSynth players advanced
/// by the render callback) asks this after every chunk and carries out the actions in order. Keeping the rules here
/// means the engines make the same decisions and the Mac tests them.
package enum PlaybackTransportStepper {
    /// Where the transport stands after a chunk.
    package struct Snapshot: Equatable, Sendable {
        package var isPlaying: Bool
        /// The score player's position, in unrolled ticks.
        package var scoreTick: Int
        /// The metronome player's position. It runs `metronomeOffsetTicks` ahead of the score: its sequence starts
        /// with the count-in's bars.
        package var metronomeTick: Int
        package var metronomeOffsetTicks: Int
        package var loop: TransportLoop?
        /// A count-in still sounding: the score starts when the metronome reaches `preRollTicks`.
        package var countIn: CountIn?
        /// The unrolled end of the score.
        package var totalTicks: Int

        package init(
            isPlaying: Bool, scoreTick: Int, metronomeTick: Int, metronomeOffsetTicks: Int, loop: TransportLoop?,
            countIn: CountIn?, totalTicks: Int,
        ) {
            self.isPlaying = isPlaying
            self.scoreTick = scoreTick
            self.metronomeTick = metronomeTick
            self.metronomeOffsetTicks = metronomeOffsetTicks
            self.loop = loop
            self.countIn = countIn
            self.totalTicks = totalTicks
        }
    }

    package struct CountIn: Equatable, Sendable {
        /// The metronome tick at which the count-in's bars are over.
        package var preRollTicks: Int
        /// Where the score starts playing when they are — the play position, or the loop's start.
        package var scoreStartTick: Int

        package init(preRollTicks: Int, scoreStartTick: Int) {
            self.preRollTicks = preRollTicks
            self.scoreStartTick = scoreStartTick
        }
    }

    package enum Action: Equatable, Sendable {
        /// Silence every sounding note (before a jump, so nothing hangs).
        case allNotesOff
        case seekScore(tick: Int)
        case seekMetronome(tick: Int)
        /// The count-in is over: start the score player at `tick`.
        case startScore(tick: Int)
        /// The loop wrapped once (for the engine's counters and the host's events).
        case wrapped
        case stopAtEnd
    }

    /// What to do now, in order. Nothing while paused or stopped, and nothing but the handover while a count-in
    /// sounds.
    package static func step(_ snapshot: Snapshot) -> [Action] {
        guard snapshot.isPlaying else { return [] }
        if let countIn = snapshot.countIn {
            guard snapshot.metronomeTick >= countIn.preRollTicks else { return [] }
            return [.startScore(tick: countIn.scoreStartTick)]
        }
        // The loop first: a loop that ends where the score does wraps rather than stopping.
        if let loop = snapshot.loop, snapshot.scoreTick >= loop.endTick {
            return [
                .allNotesOff,
                .seekScore(tick: loop.startTick),
                .seekMetronome(tick: loop.startTick + snapshot.metronomeOffsetTicks),
                .wrapped,
            ]
        }
        if snapshot.scoreTick >= snapshot.totalTicks {
            return [.allNotesOff, .stopAtEnd]
        }
        return []
    }
}
