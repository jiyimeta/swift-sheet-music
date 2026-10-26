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
        // Identified first: a repair carries every slot of its voice by identity, and only a score from a
        // producing entry point (here the editor) has identities to carry.
        var previous = ScoreEditor(score: EditingFixtures.twoMeasuresOfQuarterRests(key: 2)).score
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

    /// The same edit on a drum staff plans nothing: a drumset spells its pitches (hi-hat F♯, ride E♭, crash C♯),
    /// and renotating against those spellings wrote ♯ and ♭ onto every drum bar an edit touched — marks MuseScore
    /// never draws on a percussion staff (found 2026-09-22 in folino).
    @Test(arguments: [(group: "percussion", useDrumset: false), (group: "pitched", useDrumset: true)])
    func `an edit on a drum staff plans no glyph`(group: String, useDrumset: Bool) {
        var previous = ScoreEditor(score: EditingFixtures.twoMeasuresOfQuarterRests(key: 2)).score
        previous.parts.updateValue(at: 0) { part in
            part.instrument.useDrumset = useDrumset
            part.staves.updateValue(at: 0) { $0.group = group }
        }
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        let second = VoiceElementID(EditingFixtures.restID(element: 3))
        previous[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 42, tpc: 20)]))
        previous[second] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 51, tpc: 11)]))
        var current = previous
        current[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 46, tpc: 12)]))
        #expect(MeasureAccidentals.renotationCommands(in: current, changedFrom: previous).isEmpty)
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
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[m].voices[0].elements.updateValue(at: slot) {
                        $0 = .chord(Chord(duration: .whole, notes: [Note(pitch: 66, tpc: 20)]))
                    } // F♯4, in-key in G major
                }
            }
        }
        // Flip the stored key to C major the way SetKeySignature will: rewrite the measure-0 element.
        guard case .keySignature = score.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { Issue.record("expected key sig at [0]"); return }
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].voices[0].elements.updateValue(at: 0) {
                    $0 = .keySignature(KeySignature(concertKey: 0))
                }
            }
        }

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

    // MARK: - A tie across the barline

    /// `twoMeasuresOfQuarterRests(key:)` with `tieStart` on bar 0's last beat tied into `tied` on bar 1's first
    /// beat, then `rest` filling bar 1's following beats.
    private static func tiedAcrossTheBarline(
        key: Int = 0, tieStart: Note, tied: Note, then rest: [Note],
    ) -> Score {
        var score = ScoreEditor(score: EditingFixtures.twoMeasuresOfQuarterRests(key: key)).score
        var start = tieStart
        start.tieForward = 1
        var end = tied
        end.tieBack = 1
        score[VoiceElementID(EditingFixtures.restID(element: 5))] = .chord(Chord(duration: .quarter, notes: [start]))
        score[VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))] =
            .chord(Chord(duration: .quarter, notes: [end]))
        for (offset, note) in rest.enumerated() {
            score[VoiceElementID(EditingFixtures.restID(measure: 1, element: offset + 1))] =
                .chord(Chord(duration: .quarter, notes: [note]))
        }
        return score
    }

    private static func renotated(_ score: Score, measures: Range<Int>) -> Score {
        var repaired = score
        for command in MeasureAccidentals.renotationCommands(in: score, measureRange: measures) {
            _ = try? command.apply(to: &repaired)
        }
        return repaired
    }

    private static func accidental(_ score: Score, measure: Int, element: Int) -> Accidental? {
        score[EditingFixtures.noteID(measure: measure, element: element)]?.accidental
    }

    /// MuseScore's `TIE_CONTEXT`: a note tied over the barline with no glyph of its own leaves its line marked, so
    /// the next note on that line in the bar restates its accidental even though the alteration is the same — the
    /// reader never saw a ♯ in this bar. A note after the restated one is covered by it.
    @Test func `a note after a tied-over sharp restates the sharp`() {
        let fSharp = Note(pitch: 66, tpc: 20)
        let score = Self.tiedAcrossTheBarline(
            tieStart: Note(pitch: 66, tpc: 20, accidental: .sharp), tied: fSharp, then: [fSharp, fSharp],
        )
        let repaired = Self.renotated(score, measures: 0 ..< 2)
        #expect(Self.accidental(repaired, measure: 0, element: 5) == .sharp)
        #expect(Self.accidental(repaired, measure: 1, element: 0) == nil) // the tie carries it
        #expect(Self.accidental(repaired, measure: 1, element: 1) == .sharp) // restated
        #expect(Self.accidental(repaired, measure: 1, element: 2) == nil) // covered by the restated ♯
    }

    /// The same rule against the key: under D major a tied-over F♮ marks the line, so a later F♮ in the bar restates
    /// its ♮ — and an F♯ there is the key's own spelling, which the tied ♮ has to be cancelled for.
    @Test(arguments: [(pitch: 65, tpc: 13, expected: Accidental.natural), (pitch: 66, tpc: 20, expected: .sharp)])
    func `a tied-over natural under a sharp key restates the line`(pitch: Int, tpc: Int, expected: Accidental) {
        let score = Self.tiedAcrossTheBarline(
            key: 2,
            tieStart: Note(pitch: 65, tpc: 13, accidental: .natural),
            tied: Note(pitch: 65, tpc: 13),
            then: [Note(pitch: pitch, tpc: tpc)],
        )
        let repaired = Self.renotated(score, measures: 0 ..< 2)
        #expect(Self.accidental(repaired, measure: 1, element: 0) == nil)
        #expect(Self.accidental(repaired, measure: 1, element: 1) == expected)
    }

    /// A tied-over note that SHOWS its accidental (one the user forced) has already told the reader, so the line is
    /// not marked and the next note on it needs nothing — MuseScore sets `TIE_CONTEXT` only for a tied note without
    /// an accidental of its own.
    @Test func `a tied-over note showing its own sharp covers the next one`() {
        let score = Self.tiedAcrossTheBarline(
            tieStart: Note(pitch: 66, tpc: 20, accidental: .sharp),
            tied: Note(pitch: 66, tpc: 20, accidental: .sharp, accidentalRole: .user),
            then: [Note(pitch: 66, tpc: 20, accidental: .sharp)],
        )
        let repaired = Self.renotated(score, measures: 0 ..< 2)
        #expect(Self.accidental(repaired, measure: 1, element: 0) == .sharp)
        #expect(Self.accidental(repaired, measure: 1, element: 1) == nil)
    }

    /// A tie inside one bar marks nothing: the ♯ the reader needs is on the tie's first note, in this same bar.
    @Test func `a tie inside one bar leaves the next note covered`() {
        var score = ScoreEditor(score: EditingFixtures.twoMeasuresOfQuarterRests(key: 0)).score
        score[VoiceElementID(EditingFixtures.restID(element: 2))] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 66, tpc: 20, accidental: .sharp, tieForward: 1)]))
        score[VoiceElementID(EditingFixtures.restID(element: 3))] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 66, tpc: 20, tieBack: 1)]))
        score[VoiceElementID(EditingFixtures.restID(element: 4))] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 66, tpc: 20)]))
        let repaired = Self.renotated(score, measures: 0 ..< 1)
        #expect(Self.accidental(repaired, measure: 0, element: 2) == .sharp)
        #expect(Self.accidental(repaired, measure: 0, element: 4) == nil)
    }

    /// A letter key reads the bar the way MuseScore's `Measure::findAccidental` does: a note tied over the barline
    /// without an accidental of its own is not something the reader saw in this bar, so the letter F after a
    /// tied-over F♯ in C major writes the key's F♮ — and the renotation pass then gives it its ♮.
    @Test func `a letter key after a tied-over sharp writes the key's spelling`() throws {
        let fSharp = Note(pitch: 66, tpc: 20)
        let score = Self.tiedAcrossTheBarline(
            tieStart: Note(pitch: 66, tpc: 20, accidental: .sharp), tied: fSharp, then: [],
        )
        let slot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 1))
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "f", nearestTo: 66, at: slot, in: score,
        ))
        #expect(planned.pitch == 65)
        #expect(planned.tpc == 13)

        var written = score
        written[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: planned.pitch, tpc: planned.tpc)]))
        let repaired = Self.renotated(written, measures: 1 ..< 2)
        #expect(Self.accidental(repaired, measure: 1, element: 1) == .natural)
    }

    /// The counterpart: a tied-over note that shows its own ♯ is what the reader saw, so the letter keeps it.
    @Test func `a letter key after a tied-over note showing its sharp keeps the sharp`() throws {
        let score = Self.tiedAcrossTheBarline(
            tieStart: Note(pitch: 66, tpc: 20, accidental: .sharp),
            tied: Note(pitch: 66, tpc: 20, accidental: .sharp, accidentalRole: .user),
            then: [],
        )
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "f", nearestTo: 66, at: VoiceElementID(EditingFixtures.restID(measure: 1, element: 1)),
            in: score,
        ))
        #expect(planned.pitch == 66)
        #expect(planned.tpc == 20)
    }
}
