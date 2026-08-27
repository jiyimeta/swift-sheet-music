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

    /// A key change reaches every bar up to the next one, not just the bar the new signature lands in — and the
    /// bars after it are byte-identical to what they were, so the diff-based path cannot see them. The range API
    /// is what covers them.
    @Test func `range renotation covers measures after a key change`() {
        // Two measures of G major (1 sharp) holding F♯s spelled without glyphs (in key), then flip the score to
        // C major and ask for renotation over 0..<2: every F♯ now needs an explicit ♯ glyph.
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 1, measureCount: 2,
        ))
        for m in 0 ..< 2 {
            let slot = m == 0 ? 2 : 0
            score.parts[0].staves[0].measures[m].voices[0].elements[slot] =
                .chord(Chord(duration: .whole, notes: [Note(pitch: 66, tpc: 20)])) // F♯4, in-key in G major
        }
        // Flip the stored key to C major the way SetKeySignature will: rewrite the measure-0 element.
        guard case .keySignature = score.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { Issue.record("expected key sig at [0]"); return }
        score.parts[0].staves[0].measures[0].voices[0].elements[0] = .keySignature(KeySignature(concertKey: 0))

        let repairs = MeasureAccidentals.renotationCommands(in: score, measureRange: 0 ..< 2)
        #expect(repairs.count == 2) // BOTH measures need a repair — the diff-based path would only find bar 0
        var repaired = score
        for command in repairs {
            _ = try? command.apply(to: &repaired)
        }
        for m in 0 ..< 2 {
            let slot = m == 0 ? 2 : 0
            guard case let .chord(chord) = repaired.parts[0].staves[0].measures[m].voices[0].elements[slot]
            else { Issue.record("chord"); return }
            #expect(chord.notes[0].accidental == .sharp) // F♯ out of key now carries its glyph
        }
    }
}
