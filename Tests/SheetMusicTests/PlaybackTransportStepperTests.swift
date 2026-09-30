@testable import SheetMusicAudioCore
import Testing

@Suite("PlaybackTransportStepper")
struct PlaybackTransportStepperTests {
    private let loop = TransportLoop(startTick: 1920, endTick: 3840, startSeconds: 2, endSeconds: 4)

    private func snapshot(
        playing: Bool = true, score: Int, metronome: Int? = nil, offset: Int = 0, loop: TransportLoop? = nil,
        countIn: PlaybackTransportStepper.CountIn? = nil, total: Int = 9600,
    ) -> PlaybackTransportStepper.Snapshot {
        PlaybackTransportStepper.Snapshot(
            isPlaying: playing, scoreTick: score, metronomeTick: metronome ?? score + offset,
            metronomeOffsetTicks: offset, loop: loop, countIn: countIn, totalTicks: total,
        )
    }

    @Test("does nothing while paused, even past the loop's end and the score's")
    func idleWhenPaused() {
        #expect(PlaybackTransportStepper.step(snapshot(playing: false, score: 5000, loop: loop)).isEmpty)
        #expect(PlaybackTransportStepper.step(snapshot(playing: false, score: 9700)).isEmpty)
    }

    @Test("does nothing inside the loop")
    func insideTheLoop() {
        #expect(PlaybackTransportStepper.step(snapshot(score: 3839, loop: loop)).isEmpty)
    }

    @Test("wraps at the loop's end: notes off, both players back to the start, the metronome by its offset")
    func wraps() {
        #expect(PlaybackTransportStepper.step(snapshot(score: 3840, offset: 960, loop: loop)) == [
            .allNotesOff, .seekScore(tick: 1920), .seekMetronome(tick: 2880), .wrapped,
        ])
        // Overshooting the end by a chunk wraps the same way.
        #expect(PlaybackTransportStepper.step(snapshot(score: 3900, loop: loop)).first == .allNotesOff)
    }

    @Test("a loop that ends where the score does wraps instead of stopping")
    func loopToTheEnd() {
        let toEnd = TransportLoop(startTick: 1920, endTick: 9600, startSeconds: 2, endSeconds: 10)
        #expect(PlaybackTransportStepper.step(snapshot(score: 9600, loop: toEnd)).contains(.wrapped))
        #expect(!PlaybackTransportStepper.step(snapshot(score: 9600, loop: toEnd)).contains(.stopAtEnd))
    }

    @Test("stops at the end of the score without a loop")
    func stopsAtTheEnd() {
        #expect(PlaybackTransportStepper.step(snapshot(score: 9600)) == [.allNotesOff, .stopAtEnd])
        #expect(PlaybackTransportStepper.step(snapshot(score: 9599)).isEmpty)
    }

    @Test("during a count-in only the handover counts, and it starts the score where the count-in says")
    func countInHandover() {
        let countIn = PlaybackTransportStepper.CountIn(preRollTicks: 1920, scoreStartTick: 0)
        #expect(PlaybackTransportStepper.step(snapshot(score: 0, metronome: 1919, countIn: countIn)).isEmpty)
        #expect(
            PlaybackTransportStepper.step(snapshot(score: 0, metronome: 1920, countIn: countIn))
                == [.startScore(tick: 0)],
        )
    }

    @Test("a count-in into a loop hands over at the loop's start, and ignores the loop until then")
    func countInIntoALoop() {
        let countIn = PlaybackTransportStepper.CountIn(preRollTicks: 1920, scoreStartTick: loop.startTick)
        // The score player sits wherever it was parked; the loop's end does not fire during the count-in.
        let parked = snapshot(score: 4000, metronome: 100, loop: loop, countIn: countIn)
        #expect(PlaybackTransportStepper.step(parked).isEmpty)
        #expect(
            PlaybackTransportStepper.step(snapshot(score: 4000, metronome: 1920, loop: loop, countIn: countIn))
                == [.startScore(tick: 1920)],
        )
    }
}
