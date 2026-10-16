import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct OttavaMidiTests {
    /// Build a single-staff score where measure 1 has two quarter
    /// chords and the second is wrapped in an 8va spanner. The first
    /// chord must keep its original pitch; the second must play one
    /// octave higher.
    @Test func eightVaShiftsCoveredChord() throws {
        let cMid = Note(pitch: 60, tpc: 14)
        let cHigh = Note(pitch: 60, tpc: 14)
        let begin = Spanner(
            kind: .ottava, rawType: "Ottava",
            nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            ottava: .init(subtype: .eightVA),
        )
        let end = Spanner(
            kind: .ottava, rawType: "Ottava",
            visible: false,
        )
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [cMid])),
            .spanner(begin),
            .chord(Chord(duration: .quarter, notes: [cHigh])),
            .spanner(end),
        ])])
        let score = Score(division: 480, parts: [
            Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [m])],
            ),
        ])

        let midi = try MidiRenderer.render(score: score)
        let track = try #require(midi.tracks.last)
        let noteOns: [(tick: Int, pitch: Int)] = track.events.compactMap {
            guard case let .noteOn(_, pitch, _) = $0.event else {
                return nil
            }
            return ($0.tick, pitch)
        }
        #expect(noteOns.count == 2)
        // First chord onset at tick 0, unaffected.
        #expect(noteOns[0].pitch == 60)
        // Second chord onset at tick 480 (one quarter later) — the
        // 8va range is [480, 720) so it shifts up an octave.
        #expect(noteOns[1].pitch == 72)
    }

    /// The same construction but with an 8vb (octave-down) subtype:
    /// the covered chord must play one octave lower.
    @Test func eightVbShiftsCoveredChordDown() throws {
        let cMid = Note(pitch: 72, tpc: 14)
        let cLow = Note(pitch: 72, tpc: 14)
        let begin = Spanner(
            kind: .ottava, rawType: "Ottava",
            nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            ottava: .init(subtype: .eightVB),
        )
        let end = Spanner(
            kind: .ottava, rawType: "Ottava",
            visible: false,
        )
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [cMid])),
            .spanner(begin),
            .chord(Chord(duration: .quarter, notes: [cLow])),
            .spanner(end),
        ])])
        let score = Score(division: 480, parts: [
            Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [m])],
            ),
        ])

        let midi = try MidiRenderer.render(score: score)
        let track = try #require(midi.tracks.last)
        let noteOns: [Int] = track.events.compactMap {
            guard case let .noteOn(_, pitch, _) = $0.event else {
                return nil
            }
            return pitch
        }
        #expect(noteOns == [72, 60])
    }

    /// A chord that ends *exactly* at the spanner's end tick is NOT
    /// covered (half-open range): the spanner ends as that next chord
    /// begins.
    @Test func endTickIsHalfOpen() throws {
        let note = Note(pitch: 60, tpc: 14)
        let begin = Spanner(
            kind: .ottava, rawType: "Ottava",
            nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            ottava: .init(subtype: .eightVA),
        )
        let end = Spanner(
            kind: .ottava, rawType: "Ottava",
            visible: false,
        )
        let m = Measure(voices: [Voice(elements: [
            .spanner(begin),
            .chord(Chord(duration: .quarter, notes: [note])),
            .spanner(end),
            .chord(Chord(duration: .quarter, notes: [note])),
        ])])
        let score = Score(division: 480, parts: [
            Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [m])],
            ),
        ])
        let midi = try MidiRenderer.render(score: score)
        let track = try #require(midi.tracks.last)
        let pitches: [Int] = track.events.compactMap {
            guard case let .noteOn(_, p, _) = $0.event else { return nil }
            return p
        }
        // Inside the range → +12. After tick 480 (end of range) → original.
        #expect(pitches == [72, 60])
    }

    /// An ottava shifts the whole staff, as MuseScore applies it: the spanner sits in voice 0, and the chords of voice
    /// 1 under it are shifted too. Voice 0: 8va over the first half, C4 C4 C4(half); voice 1: G3(half) G3(half).
    @Test func ottavaInVoiceZeroShiftsEveryVoiceOfTheStaff() throws {
        let begin = Spanner(
            kind: .ottava, rawType: "Ottava",
            nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 2),
            ottava: .init(subtype: .eightVA),
        )
        let end = Spanner(kind: .ottava, rawType: "Ottava", visible: false)
        let c4 = Note(pitch: 60, tpc: 14)
        let g3 = Note(pitch: 55, tpc: 15)
        let voice0 = Voice(elements: [
            .spanner(begin),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .spanner(end),
            .chord(Chord(duration: .half, notes: [c4])),
        ])
        let voice1 = Voice(elements: [
            .chord(Chord(duration: .half, notes: [g3])),
            .chord(Chord(duration: .half, notes: [g3])),
        ])
        let score = Score(division: 480, parts: [
            Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice0, voice1])])],
            ),
        ])
        let midi = try MidiRenderer.render(score: score)
        let ons = midi.tracks.flatMap(\.events).compactMap { event -> (tick: Int, pitch: Int)? in
            guard case let .noteOn(_, pitch, _) = event.event else { return nil }
            return (event.tick, pitch)
        }
        let sorted = ons.sorted { $0.tick == $1.tick ? $0.pitch < $1.pitch : $0.tick < $1.tick }
        // Tick 0: G3 → G4 (67) in voice 1, C4 → C5 (72) in voice 0; 480: C5; 960 (range ended): G3, C4.
        #expect(sorted.map(\.tick) == [0, 0, 480, 960, 960])
        #expect(sorted.map(\.pitch) == [67, 72, 72, 55, 60])
    }
}
