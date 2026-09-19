import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// `render(score:)` for a TRANSPORT rather than for a file: the same sequence, carried to the END OF THE SCORE.
    ///
    /// Playback and export want different lengths, and this is the seam between them. `render(score:)` stays
    /// byte-faithful to MuseScore, whose own MIDI export ends one tick after the final note-off — the golden
    /// comparisons in `MidiSemanticComparison` measure exactly that, and padding it there made six of them
    /// diverge. MuseScore's PLAYBACK is a different length from MuseScore's exported file, because its transport
    /// has its own end; ours does not, so the padding has to go on the sequence a transport is handed.
    public static func renderForPlayback(score: Score) throws -> MidiFile {
        try extendingToNotatedEnd(render(score: score), score: score)
    }
}

extension MidiRenderer {
    /// Carries the rendered sequence to the NOTATED END of the score, by moving each track's end-of-track meta
    /// there.
    ///
    /// **Why the renderer and not the timeline.** What ends playback is the TRANSPORT running out, not a comparison
    /// against `PlaybackTimeline.totalTicks` — `PlaybackEngine` stops on `!sequencer.isPlaying` (AUMIDISynth) and on
    /// `backend.isAtEnd` (injected backend), the latter with a comment saying in so many words to ask the transport
    /// rather than the timeline. The timeline is already right: it walks rests, so a bar holding one quarter note
    /// and three quarter rests reports the full bar. The SMF is what was short — a rest emits no event, so
    /// end-of-track landed one tick after the final note-off and the sequencer stopped there, mid-bar, the instant
    /// the last note released.
    ///
    /// **Why the end of the score and not the bar the music stops in.** MuseScore plays a score to its end, empty
    /// bars and all, and the project owner asked for that parity (2026-09-20). This used to stop at the barline of
    /// the last bar holding sound, on the grounds that a new folino score is 32 empty bars by default and running
    /// to the notated end would answer "it stops too soon" with half a minute of silence. That trade is the user's
    /// to make and they made it the other way — and it also ends a real inconsistency, because
    /// `PlaybackTimeline` has always walked to the notated end, so the seek bar showed a length the transport
    /// refused to play.
    ///
    /// Ticks here are UNROLLED (repeats and jumps expanded) while the notated end is notated, so the distance is
    /// measured in notated space and then ADDED to the unrolled end. That holds because the unroll's FINAL span
    /// runs to the notated end: whatever the last jump was, playback leaves it at the final barline, so the tail
    /// the last event still owes is inside that same span and the sum stays on the transport's own clock.
    static func extendingToNotatedEnd(_ file: MidiFile, score: Score) -> MidiFile {
        let lastEventTick = file.tracks
            .flatMap(\.events)
            .filter { if case .endOfTrack = $0.event { false } else { true } }
            .map(\.tick)
            .max() ?? 0
        let unroll = playbackUnroll(score: score)
        let remainder = ticksToNotatedEnd(
            afterNotated: unroll.notatedTick(fromUnrolled: lastEventTick), in: score,
        )
        guard remainder > 0 else { return file }
        let endTick = lastEventTick + remainder
        var padded = file
        for trackIndex in padded.tracks.indices {
            for eventIndex in padded.tracks[trackIndex].events.indices {
                guard case .endOfTrack = padded.tracks[trackIndex].events[eventIndex].event else { continue }
                // Never pulls an end-of-track EARLIER: a track already reaching past the barline (nothing does
                // today, but a future emitter releasing a pedal or a reverb tail might) keeps its own length, and
                // `MidiWriter`'s sorted-by-tick precondition keeps holding because `endTick` is measured from the
                // last event in the WHOLE file.
                let current = padded.tracks[trackIndex].events[eventIndex].tick
                padded.tracks[trackIndex].events[eventIndex] = TimedMidiEvent(
                    tick: max(current, endTick), event: .endOfTrack,
                )
            }
        }
        return padded
    }

    /// Distance from `notated` to the score's final barline. `0` when it already sits there or past it — a score
    /// with no measures, or an event rendered beyond the notated end, has nothing ahead of it to reach and asks
    /// for no padding.
    static func ticksToNotatedEnd(afterNotated notated: Int, in score: Score) -> Int {
        let end = score.effectiveMeasureDurations()
            .reduce(0) { $0 + $1.ticks(division: score.division) }
        return max(0, end - notated)
    }
}
