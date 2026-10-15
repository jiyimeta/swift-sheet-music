@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// One-staff 4/4 scores at division 480 for the dynamics playback suites — a middle C per note, the instrument's
/// velocity scale 100 % — and the velocities their SMF sounds.
enum DynamicPlaybackFixtures {
    static let quarter = note(.quarter)
    static let half = note(.half)
    static let eighth = note(.eighth)

    static func note(_ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
    }

    static func note(_ duration: NoteDuration, pitch: Int) -> VoiceElement {
        .chord(Chord(duration: duration, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
    }

    /// A dynamic at MuseScore's velocity for its subtype, reaching `assignment`'s voices.
    static func dynamic(_ subtype: String, assignment: VoiceAssignment) -> VoiceElement {
        .dynamic(Dynamic(
            subtype: subtype, velocity: Dynamic.defaultVelocity(for: subtype), voiceAssignment: assignment,
        ))
    }

    /// A two-staff 4/4 part: `upper[bar][voice]` and `lower[bar][voice]` are each voice's elements.
    static func grandStaff(upper: [[[VoiceElement]]], lower: [[[VoiceElement]]]) -> Score {
        func staff(_ bars: [[[VoiceElement]]]) -> Staff {
            Staff(measures: bars.enumerated().map { bar, voices in
                Measure(voices: voices.enumerated().map { voice, elements in
                    let meter: [VoiceElement] = bar == 0 && voice == 0
                        ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                        : []
                    return Voice(elements: meter + elements)
                })
            })
        }
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff(upper), staff(lower)])
        return Score(division: 480, parts: [part], systemMeasures: IdentifiedArray(upper.map { _ in SystemMeasure() }))
    }

    /// Every sounding note-on's velocity on track `track` — one per staff — of `pitch` only when given, in order.
    static func velocities(_ score: Score, track: Int, pitch: Int? = nil) throws -> [Int] {
        let midi = try MidiRenderer.render(score: score)
        return midi.tracks[track].events.compactMap { timed -> Int? in
            guard case let .noteOn(_, notePitch, velocity) = timed.event, velocity > 0 else { return nil }
            if let pitch, notePitch != pitch { return nil }
            return velocity
        }
    }

    /// A dynamic at MuseScore's velocity for its subtype unless given one.
    static func dynamic(
        _ subtype: String, velocity: Int? = nil, playsBack: Bool = true, speed: Dynamic.VelocityChangeSpeed = .normal,
    ) -> VoiceElement {
        .dynamic(Dynamic(
            subtype: subtype, velocity: velocity ?? Dynamic.defaultVelocity(for: subtype),
            playsBack: playsBack, velocityChangeSpeed: speed,
        ))
    }

    /// A crescendo hairpin to the next bar's downbeat.
    static func crescendo(veloChange: Int? = nil) -> VoiceElement {
        .spanner(Spanner(
            kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 1,
            hairpin: .init(subtype: .crescendo, veloChange: veloChange),
        ))
    }

    /// A diminuendo hairpin to the next bar's downbeat.
    static func diminuendo() -> VoiceElement {
        .spanner(Spanner(
            kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 1, hairpin: .init(subtype: .decrescendo),
        ))
    }

    /// One bar per element list, the first opening with 4/4; `tempo` (quarter notes a second) at the first downbeat.
    static func score(_ bars: [[VoiceElement]], tempo: Double? = nil) -> Score {
        let measures = bars.enumerated().map { index, elements -> Measure in
            let meter: [VoiceElement] = index == 0 ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))] : []
            return Measure(voices: [Voice(elements: meter + elements)])
        }
        let lane = bars.indices.map { index -> SystemMeasure in
            guard index == 0, let tempo else { return SystemMeasure() }
            return SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: tempo))),
            ])
        }
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])
        return Score(division: 480, parts: [part], systemMeasures: IdentifiedArray(lane))
    }

    /// `score` with a repeat from bar `start` through bar `end` (0-based), played twice.
    static func repeating(_ score: Score, from start: Int, through end: Int) -> Score {
        var score = score
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[start].startRepeat = true
                staff.measures[end].endRepeatCount = 2
            }
        }
        return score
    }

    /// Every sounding note-on's velocity, in order.
    static func velocities(_ score: Score) throws -> [Int] {
        let midi = try MidiRenderer.render(score: score)
        let track = try #require(midi.tracks.first)
        return track.events.compactMap { timed -> Int? in
            guard case let .noteOn(_, _, velocity) = timed.event, velocity > 0 else { return nil }
            return velocity
        }
    }
}
