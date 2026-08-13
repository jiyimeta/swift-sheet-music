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
    /// convention). The note-off lands a half-beat later so back-to-back ticks at fast tempi don't choke each
    /// other on samplers that respect note-off.
    public static func clickTrack(beats: [MetronomeBeat], division: Int) -> MidiTrack {
        var events: [TimedMidiEvent] = []
        events.reserveCapacity(beats.count * 2 + 1)
        let halfBeat = max(1, division / 4)
        for beat in beats {
            let pitch = beat.isDownbeat ? 76 : 77
            let velocity = beat.isDownbeat ? 100 : 80
            events.append(TimedMidiEvent(
                tick: beat.tick,
                event: .noteOn(channel: 9, pitch: pitch, velocity: velocity),
            ))
            events.append(TimedMidiEvent(
                tick: beat.tick + halfBeat,
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
                    event: .meta(.tempo(
                        microsecondsPerQuarter: 60_000_000 / Int(plan.quarterBpm.rounded()),
                    )),
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
}
