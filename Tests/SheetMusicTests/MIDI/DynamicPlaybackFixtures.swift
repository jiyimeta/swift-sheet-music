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
