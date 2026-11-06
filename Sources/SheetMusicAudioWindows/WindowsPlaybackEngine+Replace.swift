import Foundation
import SheetMusicAudioCore
import SheetMusicCore

// An edit's score swap, keeping the transport (`replaceScore(with:)`): what is recorded before the swap, how it is
// found in the edited score, and how it is seated.

extension WindowsPlaybackEngine {
    /// Replaces the prepared score while keeping the synths, the mixer, rate, tuning, transposition, the master stage
    /// and the metronome — when the mixer layout is unchanged. A changed layout or an unprepared engine falls back to
    /// the full `prepare(score:)`.
    ///
    /// Either way the transport is kept, as the Apple engine's `replaceScore(with:)` keeps it: playing goes on playing,
    /// paused stays paused, from the same place — the cursor and the loop recorded as measure positions before the
    /// swap (`PlaybackMeasurePosition`, the coordinate that still names the same place once measures were inserted or
    /// removed ahead of it) and found again in the edited score. Before this an edit while playing sent playback back
    /// to the top.
    ///
    /// The in-place swap seats the transport in the same critical section as the swap, so the render never draws the
    /// stopped state between the two. As on the Apple engine: a swap during a count-in plays on from the count's start
    /// without counting again, and a playing cursor that no longer resolves (the edit removed every measure it could
    /// name) plays from the top.
    @discardableResult
    public func replaceScore(with prepared: PreparedPlayback) throws -> ScoreReplacementOutcome {
        let transport = replacementTransport()
        let seat = transport.flatMap { Self.seat($0, in: prepared.derivation) }
        let outcome = try swapScore(with: prepared, seating: seat)
        if outcome == .fullyPrepared {
            // A changed layout went through a full prepare, which owns its own locking: seated afterwards.
            restore(transport, in: prepared.score)
        }
        return outcome
    }

    /// The recorded transport found in a new score, in the unrolled ticks the players run on: what the swap's critical
    /// section sets.
    struct TransportSeat: Sendable {
        let state: PlaybackState
        /// Nil when the cursor no longer resolves.
        let tick: Int?
        let loop: (notated: LoopRange, projected: TransportLoop)?
    }

    private func replacementTransport() -> ReplacementTransport? {
        guard let timeline = loadedDerivation?.timeline else { return nil }
        return ReplacementTransport(
            state: state,
            cursor: currentCursor.flatMap { timeline.measurePosition(ofCursor: $0) },
            loop: loopRange.flatMap { timeline.measureLoop(of: $0) },
        )
    }

    private static func seat(
        _ transport: ReplacementTransport, in derivation: PlaybackScoreDerivation,
    ) -> TransportSeat {
        let timeline = derivation.timeline
        let loop = transport.loop.flatMap { timeline.loopRange(at: $0) }.map { range in
            (
                notated: range,
                projected: TransportLoop.project(
                    range, timeline: timeline, unroll: derivation.unroll,
                    unrolledTimeMap: derivation.unrolledTimeMap,
                ),
            )
        }
        let tick = transport.cursor
            .flatMap { timeline.cursor(at: $0) }
            .flatMap { timeline.frame(forCursor: $0)?.tick }
            .map { notated -> Int in
                // Into the loop, as `seek(to:)` snaps it.
                guard let range = loop?.notated, notated < range.startTick || notated >= range.endTick else {
                    return notated
                }
                return range.startTick
            }
            .map { derivation.unroll.firstUnrolledTick(forNotated: $0) }
        return TransportSeat(state: transport.state, tick: tick, loop: loop)
    }

    /// Seats the transport recorded before a full prepare (a changed layout) in the score now loaded, through the
    /// public calls: the loop first, then the cursor in the state it was in.
    private func restore(_ transport: ReplacementTransport?, in score: Score) {
        guard let transport, let timeline = loadedDerivation?.timeline else { return }
        if let loop = transport.loop.flatMap({ timeline.loopRange(at: $0) }) {
            apply(loop: loop)
        }
        let cursor = transport.cursor.flatMap { timeline.cursor(at: $0) }
        switch transport.state {
        case .playing:
            play(from: cursor, in: score)
        case .paused:
            if let cursor {
                seek(to: cursor)
                pause()
            }
        case .stopped, .exporting:
            if let cursor {
                seek(to: cursor)
            }
        }
    }
}

/// What `replaceScore(with:)` records before the swap.
private struct ReplacementTransport {
    let state: PlaybackState
    let cursor: PlaybackMeasurePosition?
    let loop: PlaybackMeasureLoop?
}
