@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Shared stream probes for the guitar-bend MIDI suites.
///
/// `resolveUnisonOverlap` rebuilds the event stream from matched intervals, so
/// an unmatched note-on becomes a zero-length note and an unmatched note-off
/// vanishes: a note-on/off BALANCE assertion downstream of it can never fail.
/// Every probe here returns ticks and pitches for that reason — assert those,
/// never bare counts.
enum GuitarBendMidiProbe {
    static func makeScore(division: Int = 480, chords: [Chord]) -> Score {
        let instrument = Instrument(id: "test", articulations: [InstrumentArticulation()])
        let voice = Voice(elements: chords.map { .chord($0) })
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        return Score(division: division, parts: [part])
    }

    static func noteOns(in track: MidiTrack) -> [(tick: Int, pitch: Int)] {
        track.events.compactMap { ev in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return (ev.tick, pitch) }
            return nil
        }
    }

    static func noteOffs(in track: MidiTrack) -> [(tick: Int, pitch: Int)] {
        track.events.compactMap { ev in
            if case let .noteOff(_, pitch, _) = ev.event { return (ev.tick, pitch) }
            if case let .noteOn(_, pitch, vel) = ev.event, vel == 0 { return (ev.tick, pitch) }
            return nil
        }
    }

    static func bends(in track: MidiTrack) -> [(tick: Int, value: Int)] {
        track.events.compactMap { ev in
            if case let .pitchBend(_, value) = ev.event { return (ev.tick, value) }
            return nil
        }
    }

    /// Wheel value for `semitones` at the 12-semitone sensitivity the track
    /// header sets — the same scaling `renderPortamento` uses.
    static func wheel(semitones: Double) -> Int {
        MidiEvent.pitchBendCenter + Int((semitones / 12.0 * 8191.0).rounded())
    }

    static func bendNote(pitch: Int, type: GuitarBendType = .bend) -> Note {
        Note(pitch: pitch, tpc: 14, guitarBend: GuitarBend(type: type))
    }
}
