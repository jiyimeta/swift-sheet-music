import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// `render(score:)` for a TRANSPORT rather than for a file: the same sequence, carried to the barline the music
    /// stops in.
    ///
    /// Playback and export want different lengths, and this is the seam between them. `render(score:)` stays
    /// byte-faithful to MuseScore, whose own MIDI export ends one tick after the final note-off — the golden
    /// comparisons in `MidiSemanticComparison` measure exactly that, and padding it there made six of them
    /// diverge. MuseScore's PLAYBACK is a different length from MuseScore's exported file, because its transport
    /// has its own end; ours does not, so the padding has to go on the sequence a transport is handed.
    public static func renderForPlayback(score: Score) throws -> MidiFile {
        try extendingToBarline(render(score: score), score: score)
    }
}

extension MidiRenderer {
    /// Carries the rendered sequence to the barline the music stops in, by moving each track's end-of-track meta
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
    /// **Why the barline and not the end of the score.** A score is padded out with empty bars long before it is
    /// filled in — a new score in folino is 32 of them by default — so running to the notated end would answer a
    /// complaint about an abrupt stop with half a minute of silence. The bar the music stops in is where a player
    /// counting along would stop, and it is what was asked for.
    ///
    /// Ticks here are UNROLLED (repeats and jumps expanded) while barlines are notated, so the distance to the
    /// barline is measured in notated space and then ADDED to the unrolled end. A span of the unroll runs to a
    /// measure boundary, so the remainder of the bar the last event sits in is inside that same span, and the sum
    /// stays on the transport's own clock without having to map a notated tick that repeats back to one of its
    /// several unrolled twins.
    static func extendingToBarline(_ file: MidiFile, score: Score) -> MidiFile {
        let lastEventTick = file.tracks
            .flatMap(\.events)
            .filter { if case .endOfTrack = $0.event { false } else { true } }
            .map(\.tick)
            .max() ?? 0
        let unroll = playbackUnroll(score: score)
        let remainder = ticksToBarline(
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

    /// Distance from `notated` to the first barline at or after it. `0` when it already sits on one — including the
    /// final barline, so a score whose last note fills its last bar is not padded by a phantom extra bar.
    static func ticksToBarline(afterNotated notated: Int, in score: Score) -> Int {
        var boundary = 0
        for duration in score.effectiveMeasureDurations() {
            if boundary >= notated { break }
            boundary += duration.ticks(division: score.division)
        }
        // A tick past the last barline (a score with no measures, or an event rendered beyond the notated end)
        // has no barline ahead of it to reach, and asks for no padding.
        return max(0, boundary - notated)
    }
}
