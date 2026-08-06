import Foundation
@testable import SheetMusicCore
import Testing

@Suite("MeasureAccidentals (direct)")
struct MeasureAccidentalsPlannerTests {
    /// D major: F and C are sharp, so the letter F must plan the ALTERED pitch (F#) — and it must plan it as the
    /// spelling the key signature already puts in force, which is what makes writing exactly that `(pitch, tpc)`
    /// need no glyph on top of it (`renotationCommands` only adds a glyph when a note's alteration differs from
    /// what's already in force). The second half is the part that actually matters — a pitch that merely LOOKS
    /// altered but is spelled wrong would still trigger a redundant glyph — so this proves it by writing the
    /// planned note and running the renotation pass over it, not just by reasoning about the tpc in prose.
    @Test func `a letter key plans the pitch the key signature spells`() throws {
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        let slot = EditingFixtures.restID(element: 2)
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "f", nearestTo: nil, at: VoiceElementID(slot), in: score,
        ))
        #expect(planned.pitch % 12 == 6) // F#
        #expect(planned.tpc == 20) // F# — the tpc a D-major key signature already spells

        var written = score
        written[VoiceElementID(slot)] = .chord(Chord(
            duration: .quarter, notes: [Note(pitch: planned.pitch, tpc: planned.tpc)],
        ))
        #expect(MeasureAccidentals.renotationCommands(in: written, changedFrom: score).isEmpty)
    }

    /// A bar whose first C is flipped to natural leaves the SECOND C reading natural to the eye while it still
    /// sounds sharp. The renotation pass is what repairs that.
    @Test func `renotation repairs a later note in the same bar`() {
        var previous = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        // Two C#5 quarters in bar 0 (elements 2 and 3), then flatten the first to C natural.
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        let second = VoiceElementID(EditingFixtures.restID(element: 3))
        previous[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        previous[second] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        var current = previous
        current[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)]))
        let repairs = MeasureAccidentals.renotationCommands(in: current, changedFrom: previous)
        #expect(!repairs.isEmpty)
    }

    @Test func `an unchanged bar needs no repairs`() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        #expect(MeasureAccidentals.renotationCommands(in: score, changedFrom: score).isEmpty)
    }
}
