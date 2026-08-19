import SheetMusicFoundation

/// Shared post-processing applied to a rendered `MidiFile` before it is handed to a software MIDI
/// synth for *playback* (both the Apple `AVAudioSequencer` path and the Android FluidSynth path).
///
/// The renderer bakes the score's mixer state (program / CC 7 channel volume) into tick-0 events so a
/// standalone SMF sounds correct. But when a live mixer owns those channels, those tick-0 events
/// fight the mixer: every backward seek / loop-wrap rewind — and the very first play, before the
/// transport has advanced past tick 0 — re-fires them and clobbers the user's volume / program. The
/// fix (proven on iOS) is to make the engine's mixer the *sole authority* for mixer-managed channels:
/// strip their baked-in CC 7 + tick-0 program, and have the engine (re)assert them directly.
///
/// This used to live only in the Apple engine; it is shared so the Android engine gets identical
/// behavior instead of re-firing the SMF's CC 7 on first play.
public enum MidiSynthPostProcess {
    /// - Parameters:
    ///   - midi: the rendered file, mutated in place.
    ///   - mixerManagedChannels: MIDI channels whose volume / program the live mixer owns (each
    ///     staff's primary channel). CC 7 and tick-0 program are stripped only on these; secondary
    ///     playback-flavour channels keep their CC 7 so the score's volume balance survives.
    public static func apply(midi: inout MidiFile, mixerManagedChannels: Set<Int>) {
        for trackIdx in midi.tracks.indices {
            var out: [TimedMidiEvent] = []
            out.reserveCapacity(midi.tracks[trackIdx].events.count + 8)
            for event in midi.tracks[trackIdx].events {
                // Reset-all-controllers (CC 121) at tick 0 would wipe the channel state the mixer
                // just asserted; drop it everywhere.
                if case let .controlChange(_, controller, _) = event.event,
                   controller == 121
                {
                    continue
                }
                // CC 7 (Channel Volume) on a mixer-owned channel — the mixer is the sole authority.
                if case let .controlChange(channel, controller, _) = event.event,
                   controller == 7,
                   mixerManagedChannels.contains(channel)
                {
                    continue
                }
                // Tick-0 program on a mixer-owned channel — the engine re-asserts it after every
                // start, so a backward seek can't chase it and clobber a program override. Mid-piece
                // program changes (tick > 0) survive.
                if case let .programChange(channel, _) = event.event,
                   event.tick == 0,
                   mixerManagedChannels.contains(channel)
                {
                    continue
                }
                out.append(event)
                // AUMIDISynth ignores an RPN data-entry MSB (CC 6) until the LSB (CC 38) also
                // arrives; emit a zero LSB right after so pitch-bend sensitivity locks in.
                if case let .controlChange(channel, controller, _) = event.event,
                   controller == 6
                {
                    out.append(TimedMidiEvent(
                        tick: event.tick,
                        event: .controlChange(channel: channel, controller: 38, value: 0),
                    ))
                }
            }
            midi.tracks[trackIdx] = MidiTrack(events: out)
        }
    }
}
