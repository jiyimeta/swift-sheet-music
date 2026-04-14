import Foundation

/// Renders a `Score` into a `MidiFile`. Scope: midi01 vertical slice only.
/// Anything not in midi01 (multi-staff with multi-channel, multi-voice, ornaments,
/// dynamics, repeats, etc.) is intentionally not handled here; future tests will
/// extend this in additive ways.
public enum MidiRenderer {
    /// Default base velocity for "mf" (which is what midi01 implicitly uses when
    /// there are no Dynamics). C++: see compatmidirender.cpp velocity computation.
    private static let defaultDynamicVelocity = 80

    /// Default tempo if the score has no <Tempo> markers (120 BPM = 500000 µs/quarter).
    private static let defaultMicrosPerQuarter = 500_000

    /// Render the given `Score` into a `MidiFile` ready for serialisation.
    public static func render(score: Score) throws -> MidiFile {
        var tracks: [MidiTrack] = []

        for (staffIndex, staff) in score.staves.enumerated() {
            let part = try part(forStaffId: staff.id, in: score)
            let channel = staffIndex   // midi01: one staff = channel 0

            var events: [TimedMidiEvent] = []

            // ---- Header at tick 0 (mirrors writeHeader + per-channel init in exportmidi.cpp) ----
            let trackName = part.trackName ?? part.instrument.longName ?? "Track"
            events.append(TimedMidiEvent(tick: 0, event: .meta(.trackName(trackName))))

            let initialTimeSig = firstTimeSignature(in: staff) ?? TimeSignature(numerator: 4, denominator: 4)
            events.append(TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: initialTimeSig.numerator,
                denominator: initialTimeSig.denominator,
                clocksPerClick: 24,
                thirtySecondsPerQuarter: 8
            ))))

            let initialKey = firstKeySignature(in: staff) ?? KeySignature(concertKey: 0)
            let keyMeta = MetaEvent.keySignature(sharpsFlats: initialKey.concertKey, isMinor: false)
            events.append(TimedMidiEvent(tick: 0, event: .meta(keyMeta)))

            let tempoMeta = MetaEvent.tempo(microsecondsPerQuarter: defaultMicrosPerQuarter)
            events.append(TimedMidiEvent(tick: 0, event: .meta(tempoMeta)))

            func cc(_ controller: Int, _ value: Int) {
                let event = MidiEvent.controlChange(channel: channel, controller: controller, value: value)
                events.append(TimedMidiEvent(tick: 0, event: event))
            }

            // Reset all controllers, then RPN to set pitch-bend range = 12 semitones.
            cc(121, 0)
            cc(100, 0)
            cc(101, 0)
            cc(6, 12)
            cc(100, 127)
            cc(101, 127)

            // Program + per-channel CC defaults
            let ch = part.instrument.channel
            events.append(TimedMidiEvent(tick: 0, event: .programChange(channel: channel, program: ch.program)))
            cc(7, ch.volume)
            cc(10, ch.pan)
            cc(91, ch.reverb)
            cc(93, ch.chorus)

            events.append(TimedMidiEvent(tick: 0, event: .meta(.portChange(port: 0))))

            // ---- Notes ----
            var tick = 0
            for measure in staff.measures {
                guard let voice = measure.voices.first else { continue }
                if measure.voices.count > 1 {
                    throw MuseScoreParserError.unsupportedFeature(
                        name: "multi-voice measure",
                        location: "Staff \(staff.id)"
                    )
                }
                for element in voice.elements {
                    switch element {
                    case .keySignature, .timeSignature:
                        // Initial key/time sig emitted by header pass above.
                        // Mid-staff changes are not in midi01 scope; future tests will
                        // walk a KeyList/SigMap-style aggregation across measures.
                        continue
                    case .rest(let rest):
                        tick += rest.duration.ticks(division: score.division)
                    case .chord(let chord):
                        let durationTicks = chord.duration.ticks(division: score.division)
                        let articulationScale = defaultArticulationVelocityScale(for: part.instrument)
                        let velocity = defaultDynamicVelocity * articulationScale / 100
                        let offTick = tick + durationTicks - 1
                        for note in chord.notes {
                            let on = MidiEvent.noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
                            let off = MidiEvent.noteOff(channel: channel, pitch: note.pitch, velocity: 0)
                            events.append(TimedMidiEvent(tick: tick, event: on))
                            events.append(TimedMidiEvent(tick: offTick, event: off))
                        }
                        tick += durationTicks
                    }
                }
            }

            // ---- End of track ----
            // Use the post-voice tick so EoT lands one tick after the final note-off
            // (matches MuseScore's behaviour of placing EoT at end-of-music tick).
            events.append(TimedMidiEvent(tick: tick, event: .endOfTrack))

            // Stable sort by tick (preserves header insertion order at tick 0).
            let sorted = events.enumerated()
                .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
                .map(\.element)

            tracks.append(MidiTrack(events: sorted))
        }

        return MidiFile(division: score.division, format: 1, tracks: tracks)
    }

    private static func part(forStaffId id: Int, in score: Score) throws -> Part {
        // mscx assigns staves to parts in document order; midi01 has one of each.
        guard let part = score.parts.first else {
            throw MuseScoreParserError.malformedScore(reason: "Score has no parts")
        }
        _ = id
        return part
    }

    private static func firstTimeSignature(in staff: StaffContent) -> TimeSignature? {
        for measure in staff.measures {
            for voice in measure.voices {
                for element in voice.elements {
                    if case .timeSignature(let t) = element { return t }
                }
            }
        }
        return nil
    }

    private static func firstKeySignature(in staff: StaffContent) -> KeySignature? {
        for measure in staff.measures {
            for voice in measure.voices {
                for element in voice.elements {
                    if case .keySignature(let k) = element { return k }
                }
            }
        }
        return nil
    }

    private static func defaultArticulationVelocityScale(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.velocity ?? 100
    }
}
