import SheetMusicFoundation
import SheetMusicMIDI

/// Builds the MIDI the metronome is played from. Shared by every backend that schedules clicks off a
/// sequence rather than firing them by hand: the Apple `AVAudioSequencer` engine, the SwiftySynth backend,
/// and the Android FluidSynth engine all consume what this produces, so a click lands on the same tick with
/// the same pitch and velocity on every platform.
///
/// Mirrors MuseScore's metronome track:
///
///   * Strong (downbeat) → MIDI note 76 (Hi Wood Block), velocity 100
///   * Other beat → MIDI note 77 (Low Wood Block), velocity 80
///
/// Hi/Low Wood Block are GM percussion notes 76 / 77 — the same drum-kit slots MuseScore's
/// `buildMetronomeEvent` writes into when it emits E5 / F5 on the metronome track
/// (`src/engraving/playback/playbackeventsrenderer.cpp`).
public enum MetronomeSequenceBuilder {
    /// A one-track click patch: each beat emits a NoteOn / NoteOff pair on MIDI channel 9 (the GM percussion
    /// convention). The note-off lands a sixteenth later so back-to-back ticks at fast tempi don't choke each
    /// other on samplers that respect note-off — or at the next click, when that comes sooner.
    public static func clickTrack(beats: [MetronomeBeat], division: Int) -> MidiTrack {
        var events: [TimedMidiEvent] = []
        events.reserveCapacity(beats.count * 2 + 1)
        let release = max(1, division / 4)
        let beats = beats.sorted { $0.tick < $1.tick }
        for (index, beat) in beats.enumerated() {
            let pitch = beat.isDownbeat ? 76 : 77
            let velocity = beat.isDownbeat ? 100 : 80
            // A beat closer than a sixteenth to the next one — a 32nd-note meter, a pickup shorter than a
            // sixteenth, a measure that ends just past a beat — must not hold its click past that next click:
            // the note-off would land after the next note-on, and an SMF track cannot go back in time.
            let nextTick = index + 1 < beats.count ? beats[index + 1].tick : Int.max
            events.append(TimedMidiEvent(
                tick: beat.tick,
                event: .noteOn(channel: 9, pitch: pitch, velocity: velocity),
            ))
            events.append(TimedMidiEvent(
                tick: min(beat.tick + release, nextTick),
                event: .noteOff(channel: 9, pitch: pitch, velocity: 0),
            ))
        }
        let lastTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastTick + 1, event: .endOfTrack))
        return MidiTrack(events: events)
    }

    /// A metronome-ONLY sequence — the score's tempo / time-signature map plus the click track — for a backend
    /// that plays the metronome on a separate synth so it can be muted live without touching the score
    /// transport. The tempo map is copied verbatim from `rendered` so the metronome transport's seconds clock
    /// matches the score's tick-for-tick and the two stay in sync while both are advanced by the same number
    /// of rendered frames.
    ///
    /// When `plan` is non-nil (a count-in), the clicks and the tempo map are shifted exactly as the score
    /// sequence is shifted — content at `baseTick` moves to `plan.preRollTicks`, with a governing tempo seeded
    /// at tick 0 — so the body metronome lines up with the delayed score. The always-on pre-roll click itself
    /// belongs to whatever the backend counts in with, not here.
    /// - Parameter includingPreRollClicks: whether `plan.beats` are written into the click track as well.
    ///   Backends that count in on this same transport (Android) need them here; ones that put the
    ///   always-on pre-roll track in the score sequence instead (the Apple engine) must not have them
    ///   duplicated.
    public static func metronomeOnlySequence(
        rendered: MidiFile,
        metronomeBeats: [MetronomeBeat],
        plan: CountInBeats.Result? = nil,
        baseTick: Int = 0,
        includingPreRollClicks: Bool = false,
    ) -> MidiFile {
        let division = rendered.division
        var conductor: [TimedMidiEvent] = []
        for track in rendered.tracks {
            for event in track.events {
                guard case let .meta(meta) = event.event else { continue }
                switch meta {
                case .tempo, .timeSignature:
                    conductor.append(event)
                default:
                    break
                }
            }
        }
        conductor.sort { $0.tick < $1.tick }

        var beats = metronomeBeats
        if let plan {
            let shift = plan.preRollTicks - baseTick
            conductor = conductor
                .filter { $0.tick >= baseTick }
                .map { TimedMidiEvent(tick: $0.tick + shift, event: $0.event) }
            conductor.insert(
                TimedMidiEvent(
                    tick: 0,
                    event: .meta(.tempo(microsecondsPerQuarter: plan.microsecondsPerQuarter)),
                ),
                at: 0,
            )
            beats = metronomeBeats
                .filter { $0.tick >= baseTick }
                .map { MetronomeBeat(tick: $0.tick + shift, isDownbeat: $0.isDownbeat) }
            if includingPreRollClicks {
                // The pre-roll's own clicks fill `[0, preRollTicks)`, ahead of the shifted body.
                beats = plan.beats + beats
            }
        }

        return MidiFile(
            division: division,
            tracks: [MidiTrack(events: conductor), clickTrack(beats: beats, division: division)],
        )
    }

    /// A count-in's click sequence for a backend that plays the metronome as ONE sequence on its own synth (Windows'
    /// and Android's SwiftySynth host, one sequence per synth): the pre-roll and the body from `baseTick` on, as
    /// `metronomeOnlySequence(... includingPreRollClicks: true)` writes them, then the WHOLE body again, from tick 0,
    /// starting at `wholeBodyTick`. A loop wrap during that play moves on to the whole copy instead of a second
    /// sequence — so nothing is attached on the render thread — and the clicks before `baseTick` the first part drops
    /// are there for it.
    ///
    /// Positions: score tick `t` is metronome tick `t + (plan.preRollTicks - baseTick)` in the first part and
    /// `t + wholeBodyTick` in the copy — the two values of the one offset a backend keeps
    /// (`metronomeTick(forScoreTick:offset:)`).
    ///
    /// - Parameter bodyEndTick: the score's end (unrolled). The copy starts past where the first part maps it, and
    ///   past the pre-roll, so its tempo map never reaches back into a stretch the first part is still playing — a
    ///   score running on after its last click, or a count whose bars outlast the last body beat.
    public static func countInSequenceWithWholeBody(
        rendered: MidiFile,
        metronomeBeats: [MetronomeBeat],
        plan: CountInBeats.Result,
        baseTick: Int,
        bodyEndTick: Int,
    ) -> (file: MidiFile, wholeBodyTick: Int) {
        let first = metronomeOnlySequence(
            rendered: rendered, metronomeBeats: metronomeBeats, plan: plan, baseTick: baseTick,
            includingPreRollClicks: true,
        )
        let body = metronomeOnlySequence(rendered: rendered, metronomeBeats: metronomeBeats)
        let firstEnd = first.tracks.flatMap(\.events).map(\.tick).max() ?? 0
        let wholeBodyTick = max(
            firstEnd,
            metronomeTick(forScoreTick: max(bodyEndTick, baseTick), offset: plan.preRollTicks - baseTick),
        ) + 1
        // The copy's governing tempo at its own tick 0: the body's first tempo there, else the SMF default, so the
        // first part's last tempo cannot carry into it.
        let bodyConductor = body.tracks[0].events
        let hasTempoAtZero = bodyConductor.contains {
            if $0.tick == 0, case .meta(.tempo) = $0.event { return true }
            return false
        }
        var conductor = first.tracks[0].events
        if !hasTempoAtZero {
            conductor.append(TimedMidiEvent(
                tick: wholeBodyTick, event: .meta(.tempo(microsecondsPerQuarter: defaultMicrosecondsPerQuarter)),
            ))
        }
        conductor += bodyConductor.map { TimedMidiEvent(tick: $0.tick + wholeBodyTick, event: $0.event) }
        let firstClicks = first.tracks[1].events.filter {
            if case .endOfTrack = $0.event { return false }
            return true
        }
        let bodyClicks = body.tracks[1].events.map { TimedMidiEvent(tick: $0.tick + wholeBodyTick, event: $0.event) }
        return (
            MidiFile(division: rendered.division, tracks: [
                MidiTrack(events: conductor), MidiTrack(events: firstClicks + bodyClicks),
            ]),
            wholeBodyTick,
        )
    }

    /// The SMF default before any tempo event: 120 bpm.
    static let defaultMicrosecondsPerQuarter = 500_000

    /// The metronome sequence's tick for score tick `scoreTick`: `scoreTick + offset`, where `offset` is the one a
    /// backend keeps — 0 on the plain body sequence, `plan.preRollTicks - baseTick` in a count-in's first part,
    /// `wholeBodyTick` in its whole copy. Every seek, wrap, cursor and position mapping goes through here, so the
    /// offset is never added by hand in two places.
    public static func metronomeTick(forScoreTick scoreTick: Int, offset: Int) -> Int {
        scoreTick + offset
    }
}
