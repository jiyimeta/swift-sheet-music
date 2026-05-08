import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct OttavaMidiTests {
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
            ottava: .init(subtype: .eightVA)
        )
        let end = Spanner(
            kind: .ottava, rawType: "Ottava",
            visible: false
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
                staves: [Staff(measures: [m])]
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
            ottava: .init(subtype: .eightVB)
        )
        let end = Spanner(
            kind: .ottava, rawType: "Ottava",
            visible: false
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
                staves: [Staff(measures: [m])]
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
            ottava: .init(subtype: .eightVA)
        )
        let end = Spanner(
            kind: .ottava, rawType: "Ottava",
            visible: false
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
                staves: [Staff(measures: [m])]
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
}
