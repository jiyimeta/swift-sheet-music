@testable import SheetMusicCore
import Testing

/// Note input and pitch edits addressed in the WRITTEN space of a transposing staff.
///
/// The score is stored in concert pitch and rendered through `writtenPitchView()`, so every assertion here is
/// phrased the same way: plan (or edit) against the concert score, then read the result back through
/// `writtenPitchView()` and check it is what the STAFF should read. Asserting on the concert pair alone would
/// pass on a spelling that is enharmonically right and typographically wrong (D𝄫 where the user typed C), which
/// is exactly the failure the written-space routing exists to stop.
@Suite("Written-space input")
struct WrittenInputTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    /// `Score.blank` lays measure 0 out as [0] key signature, [1] time signature, [2] measure rest.
    private static let slot = VoiceElementID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
    )
    private static let note = NoteID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0,
    )

    /// One B♭ clarinet staff (`writtenPitchOffset` +2, `writtenFifthsOffset` +2), one bar of measure rest.
    private func clarinet(concertKey: Int = 0) -> Score {
        Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(
                instrumentID: "clarinet",
                staves: [.init(clefType: "G")],
                transposeDiatonic: -1,
                transposeChromatic: -2,
            )],
            concertKey: concertKey, measureCount: 1,
        ))
    }

    private func flute(concertKey: Int = 0) -> Score {
        Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "flute", staves: [.init(clefType: "G")])],
            concertKey: concertKey, measureCount: 1,
        ))
    }

    /// `score` with a quarter note of `(pitch, tpc)` written into the planning slot.
    private func writing(_ pitch: Int, _ tpc: Int, into score: Score) -> Score {
        var copy = score
        copy[Self.slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
        return copy
    }

    /// What the staff READS at the planning slot after `score` is rendered.
    private func displayed(in score: Score) -> Note? {
        guard case let .chord(chord) = score.writtenPitchView()[Self.slot] else { return nil }
        return chord.notes.first
    }

    // MARK: - plannedConcertPitch

    /// The wrapper is "resolve in the written view, then convert the answer back". Concert C major reads as D
    /// major on a B♭ clarinet, so the letter C means the C♯ the written key signature already spells — concert
    /// B♮, not the concert C that the concert-score planner would have written (and that engraves as a D).
    @Test func `a letter key means the letter the transposing staff reads`() throws {
        let score = clarinet()
        let expected = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "C", nearestTo: nil, at: Self.slot, in: score.writtenPitchView(),
        ))
        #expect(expected.pitch == 61) // written C♯4
        #expect(expected.tpc == 21)

        let planned = try #require(MeasureAccidentals.plannedConcertPitch(
            forWrittenLetter: "C", nearestTo: nil, at: Self.slot, in: score,
        ))
        #expect(planned.pitch == expected.pitch - 2) // concert B♮3
        #expect(planned.tpc == expected.tpc - 2)

        // The half that actually matters: written back into the score, the staff reads what was asked for.
        let read = try #require(displayed(in: writing(planned.pitch, planned.tpc, into: score)))
        #expect(read.pitch == expected.pitch)
        #expect(read.tpc == expected.tpc)
    }

    /// The concert-score planner is what the letter used to reach, and it is the wrong answer: written as a
    /// concert C, the clarinet staff reads D.
    @Test func `the concert planner would have engraved the wrong letter`() throws {
        let score = clarinet()
        let concert = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "C", nearestTo: nil, at: Self.slot, in: score,
        ))
        let read = try #require(displayed(in: writing(concert.pitch, concert.tpc, into: score)))
        #expect(read.tpc == 16) // D, not the C the user typed
    }

    @Test func `a non-transposing staff falls through to plannedPitch`() {
        let score = flute(concertKey: 2)
        for letter in "CDEFGAB" {
            let plain = MeasureAccidentals.plannedPitch(
                forLetter: letter, nearestTo: 60, at: Self.slot, in: score,
            )
            let written = MeasureAccidentals.plannedConcertPitch(
                forWrittenLetter: letter, nearestTo: 60, at: Self.slot, in: score,
            )
            #expect(plain?.pitch == written?.pitch)
            #expect(plain?.tpc == written?.tpc)
        }
    }

    /// The reference pitch stays CONCERT at the call site — the octave search runs in written space, so the
    /// wrapper is what converts it. Concert A3 (57) is written B3 (59), and the nearest written C to B3 is C4,
    /// which sounds concert B♭3 (58).
    @Test func `the reference pitch is concert and is converted for the octave search`() throws {
        let score = clarinet()
        let planned = try #require(MeasureAccidentals.plannedConcertPitch(
            forWrittenLetter: "C", nearestTo: 57, at: Self.slot, in: score,
        ))
        let read = try #require(displayed(in: writing(planned.pitch, planned.tpc, into: score)))
        #expect(read.pitch == 61) // written C♯4 — the octave above the written reference B3
        #expect(read.tpc == 21)
    }

    /// A written key signature that had to be respelled back into `[-7, +7]` moves the notes by `newKey −
    /// oldKey`, NOT by the instrument's own fifths offset. Concert F♯ major (+6) on a clarinet would want +8, so
    /// the staff is written in A♭ major (−4) and every note shifts −10 fifths instead of +2. Inverting with the
    /// instrument offset instead spells the letter C as a D𝄫 — the same sound, the wrong line of the staff.
    @Test func `a respelled written key inverts by the key's own shift, not the instrument's`() throws {
        let score = clarinet(concertKey: 6)
        #expect(score.writtenPitchView().activeKey(staff: Self.staff, measureIndex: 0) == -4)

        let planned = try #require(MeasureAccidentals.plannedConcertPitch(
            forWrittenLetter: "C", nearestTo: nil, at: Self.slot, in: score,
        ))
        let read = try #require(displayed(in: writing(planned.pitch, planned.tpc, into: score)))
        #expect(read.tpc == 14) // written C natural — A♭ major leaves C alone
        #expect(read.pitch == 60)
    }

    // MARK: - The relative operations need no written-space routing

    /// `Note.shifted(bySemitones:in:)` on the CONCERT note under the CONCERT key already lands on the written
    /// spelling, so the ▴/▾ keys need no wrapper. MuseScore's rule branches on `tpc > TPC_A + keySig` (and
    /// `TPC_C + keySig` downward), and the written view adds the SAME `newKey − oldKey` to the note's tpc and to
    /// the key — so both sides of the comparison move together and the branch, and therefore the ±5 / ±7 step,
    /// is identical in either space. This test is the standing proof of that; if it ever fails, the ▴/▾ keys
    /// need the written-space helper this suite deliberately does not have.
    @Test(arguments: [0, 6, -5], [1, -1, 3, -4])
    func `a concert-space semitone shift already lands on the written spelling`(
        concertKey: Int, delta: Int,
    ) throws {
        let score = writing(70, 12, into: clarinet(concertKey: concertKey)) // concert B♭4
        let written = score.writtenPitchView()
        let writtenNote = try #require(written[Self.note])
        let inWrittenSpace = try #require(writtenNote.shifted(
            bySemitones: delta, in: written.activeKey(staff: Self.staff, measureIndex: 0),
        ))

        let concertNote = try #require(score[Self.note])
        let inConcertSpace = try #require(concertNote.shifted(
            bySemitones: delta, in: score.activeKey(staff: Self.staff, measureIndex: 0),
        ))
        let read = try #require(displayed(in: writing(inConcertSpace.pitch, inConcertSpace.tpc, into: score)))
        #expect(read.pitch == inWrittenSpace.pitch)
        #expect(read.tpc == inWrittenSpace.tpc)
    }

    /// An octave is transposition-invariant, so the long-press ▴/▾ needs nothing either.
    @Test func `an octave shift is transposition-invariant`() throws {
        let score = writing(70, 12, into: clarinet())
        let read = try #require(displayed(in: writing(82, 12, into: score)))
        #expect(read.pitch == 84)
        #expect(read.tpc == 14) // still a written C, an octave up
    }

    // MARK: - SetAccidental

    /// ♯ means "sharpen the note on the page". Respelling in concert space preserves the CONCERT letter, which
    /// is a different letter: concert B♭ (written C) sharpened concert-side becomes B♯, and B♯ on a clarinet
    /// engraves as C𝄪 — the user tapped ♯ on a C and got a double sharp a tone above.
    @Test func `sharp respells the letter the staff reads, not the concert letter`() throws {
        var score = writing(70, 12, into: clarinet()) // concert B♭4 = written C5
        _ = try SetAccidental(at: Self.note, accidental: .sharp).apply(to: &score)

        let stored = try #require(score[Self.note])
        #expect(stored.pitch == 71) // concert B♮4
        #expect(stored.tpc == 19)

        let read = try #require(displayed(in: score))
        #expect(read.pitch == 73) // written C♯5
        #expect(read.tpc == 21)
    }

    @Test func `flat respells the letter the staff reads`() throws {
        var score = writing(70, 12, into: clarinet()) // written C5
        _ = try SetAccidental(at: Self.note, accidental: .flat).apply(to: &score)

        let read = try #require(displayed(in: score))
        #expect(read.pitch == 71) // written C♭5
        #expect(read.tpc == 7)
    }

    /// The inverse command undoes to the note that was there, unchanged by the written-space detour.
    @Test func `the inverse restores the concert note verbatim`() throws {
        let original = writing(70, 12, into: clarinet())
        var score = original
        let inverse = try SetAccidental(at: Self.note, accidental: .sharp).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test func `a non-transposing staff respells exactly as before`() throws {
        var score = writing(60, 14, into: flute()) // C4
        _ = try SetAccidental(at: Self.note, accidental: .sharp).apply(to: &score)
        let stored = try #require(score[Self.note])
        #expect(stored.pitch == 61)
        #expect(stored.tpc == 21)
        #expect(stored.accidental == .sharp)
    }
}
