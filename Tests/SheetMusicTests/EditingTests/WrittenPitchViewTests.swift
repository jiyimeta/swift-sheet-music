@testable import SheetMusicCore
import Testing

@Suite("Written-pitch view")
struct WrittenPitchViewTests {
    /// Part 0: flute (concert), part 1: B♭ clarinet — both one G staff, C major, one whole note concert B♭4.
    private func ensemble() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "flute", staves: [.init(clefType: "G")]),
                .init(
                    instrumentID: "clarinet",
                    staves: [.init(clefType: "G")],
                    transposeDiatonic: -1,
                    transposeChromatic: -2,
                ),
            ],
            measureCount: 1,
        ))
        for partIndex in score.parts.indices {
            score.parts[partIndex].staves[0].measures[0].voices[0].elements[2] =
                .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
        }
        return score
    }

    private func chord(_ score: Score, part: Int, measure: Int, element: Int) -> Chord? {
        guard case let .chord(c) = score.parts[part].staves[0]
            .measures[measure].voices[0].elements[element] else { return nil }
        return c
    }

    private func key(_ score: Score, part: Int, measure: Int, element: Int) -> Int? {
        guard case let .keySignature(k) = score.parts[part].staves[0]
            .measures[measure].voices[0].elements[element] else { return nil }
        return k.concertKey
    }

    @Test func transposingPartMovesConcertPartStays() {
        let written = ensemble().writtenPitchView()
        // Flute untouched.
        guard let flute = chord(written, part: 0, measure: 0, element: 2) else {
            Issue.record("flute")
            return
        }
        #expect(flute.notes.first?.pitch == 70)
        #expect(flute.notes.first?.tpc == 12)
        #expect(key(written, part: 0, measure: 0, element: 0) == 0)
        // Clarinet: concert B♭4 displays as written C5; key sig C major stays 0 + 2 = D major.
        guard let cl = chord(written, part: 1, measure: 0, element: 2) else {
            Issue.record("clarinet")
            return
        }
        #expect(cl.notes.first?.pitch == 72)
        #expect(cl.notes.first?.tpc == 14)
        #expect(key(written, part: 1, measure: 0, element: 0) == 2)
    }

    @Test func nonTransposingScoreReturnsSelf() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T", parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 1,
        ))
        #expect(score.writtenPitchView() == score)
    }

    /// Tick structure, IDs and element ordering must be untouched — the view is display-only and playback keeps
    /// reading the concert score through the same addresses.
    @Test func elementShapeIsUnchanged() {
        let score = ensemble()
        let written = score.writtenPitchView()
        #expect(written.parts.count == score.parts.count)
        for partIndex in score.parts.indices {
            let before = score.parts[partIndex].staves[0].measures[0].voices[0].elements
            let after = written.parts[partIndex].staves[0].measures[0].voices[0].elements
            #expect(before.count == after.count)
            #expect(
                before.map { $0.tickCount(division: score.division) }
                    == after.map { $0.tickCount(division: written.division) },
            )
        }
    }

    /// The in-loop `useDrumset` guard, not the top-level fast path: a SECOND transposing part (an F horn,
    /// `writtenFifthsOffset +1`) keeps `writtenPitchView()` past its early return, so the loop actually runs and
    /// has to skip the drumset part on its own. Without the horn the whole score short-circuits to `self` and the
    /// guard is never reached.
    @Test func drumsetPartIsNotShifted() {
        var score = ensemble()
        score.parts[1].instrument.useDrumset = true
        var hornStaff = score.parts[0].staves[0]
        hornStaff.measures[0].voices[0].elements[2] =
            .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
        score.parts.append(Part(
            id: "3",
            instrument: Instrument(id: "horn", transposeDiatonic: -4, transposeChromatic: -7),
            staves: [hornStaff],
        ))

        let written = score.writtenPitchView()
        // The drumset clarinet is untouched — pitch, spelling and key signature all stay concert.
        #expect(chord(written, part: 1, measure: 0, element: 2)?.notes.first?.pitch == 70)
        #expect(chord(written, part: 1, measure: 0, element: 2)?.notes.first?.tpc == 12)
        #expect(key(written, part: 1, measure: 0, element: 0) == 0)
        #expect(written.parts[1] == score.parts[1])
        // …while the horn beside it did move, proving the loop ran rather than short-circuiting.
        #expect(chord(written, part: 2, measure: 0, element: 2)?.notes.first?.pitch == 77)
        #expect(chord(written, part: 2, measure: 0, element: 2)?.notes.first?.tpc == 13)
        #expect(key(written, part: 2, measure: 0, element: 0) == 1)
    }

    @Test func percussionStaffIsNotShifted() {
        var score = ensemble()
        score.parts[1].staves[0].group = "percussion"
        let written = score.writtenPitchView()
        #expect(chord(written, part: 1, measure: 0, element: 2)?.notes.first?.pitch == 70)
        #expect(key(written, part: 1, measure: 0, element: 0) == 0)
    }

    /// Chord symbols move with the notes so a lead sheet's symbols keep naming what is written under them.
    @Test func harmonyMovesWithTheNotes() {
        var score = ensemble()
        score.parts[1].staves[0].measures[0].voices[0].elements
            .append(.harmony(Harmony(name: "7", rootTpc: 12, bassTpc: 12)))
        let written = score.writtenPitchView()
        guard case let .harmony(h) = written.parts[1].staves[0].measures[0].voices[0].elements[3]
        else {
            Issue.record("harmony")
            return
        }
        #expect(h.rootTpc == 14)
        #expect(h.bassTpc == 14)
    }

    /// A measure that inherits its key from an EARLIER measure must resolve that key against the original score.
    /// Resolving it against the partially rewritten copy reads a key that has already been shifted once and shifts
    /// it again: here measure 2 inherits B major (+5); the correct written key context is +7 (fifthsDelta +2, D →
    /// E), while a copy-resolved read would see +7 already, respell 9 → −3 and move the note by −10 fifths instead.
    @Test func midScoreKeyChangeIsResolvedAgainstTheOriginalScore() {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            // writtenFifthsOffset == +2
            parts: [.init(
                instrumentID: "clarinet",
                staves: [.init(clefType: "G")],
                transposeDiatonic: -1,
                transposeChromatic: -2,
            )],
            concertKey: 3, measureCount: 3,
        ))
        // Measure 1 modulates to B major (+5); measure 2 inherits it and carries the note.
        score.parts[0].staves[0].measures[1].voices[0].elements
            .insert(.keySignature(KeySignature(concertKey: 5)), at: 0)
        score.parts[0].staves[0].measures[2].voices[0].elements[0] =
            .chord(Chord(duration: .whole, notes: [Note(pitch: 74, tpc: 16)])) // concert D5

        let written = score.writtenPitchView()
        #expect(key(written, part: 0, measure: 0, element: 0) == 5) // A → B
        #expect(key(written, part: 0, measure: 1, element: 0) == 7) // B → C♯
        // Concert D5 (tpc 16) written as E5 (tpc 18) — a +2 fifths shift, not the −10 a double-shift would give.
        let note = chord(written, part: 0, measure: 2, element: 0)?.notes.first
        #expect(note?.pitch == 76)
        #expect(note?.tpc == 18)
    }
}
