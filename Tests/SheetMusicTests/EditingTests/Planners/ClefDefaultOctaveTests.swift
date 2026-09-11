@testable import SheetMusicCore
import SheetMusicLayout
import Testing

/// The octave a letter key writes when there is NO previous note to measure against.
///
/// That case is not an edge: it is every note typed into a freshly created score until the first one lands, and it
/// recurs on every staff the caret visits for the first time. The answer used to be a hard-coded octave 4 whatever
/// the clef said, which put A three ledger lines above a bass staff.
@Suite("Clef-driven default octave")
struct ClefDefaultOctaveTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    /// `Score.blank` lays measure 0 out as [0] key signature, [1] time signature, [2] measure rest.
    private static let firstSlot = VoiceElementID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
    )

    private static func score(clefType: String, measureCount: Int = 1, concertKey: Int = 0) -> Score {
        Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "x", staves: [.init(clefType: clefType)])],
            concertKey: concertKey, measureCount: measureCount,
        ))
    }

    /// The property the user actually asked for, asserted as a property rather than as seven pitch literals: every
    /// letter, under every pitched clef, lands on or between the staff's own five lines.
    ///
    /// `StaffStep` counts half-spaces from the middle line, so the five lines and four spaces of a staff are
    /// exactly `-4 ... 4`. Reading the result back through `PitchStaffPosition` — the same function that decides
    /// where layout DRAWS the notehead — is what makes this a claim about what the user sees rather than about an
    /// arithmetic convention shared by the code and its test.
    @Test(arguments: ["G", "F", "C1", "C3", "C4", "C5", "G8va", "G8vb", "G15ma", "G15mb", "F8va", "F8vb"])
    func `every letter lands inside the staff`(clefType: String) throws {
        let score = Self.score(clefType: clefType)
        let clef = NotatedClef(rawType: clefType)
        for letter in "abcdefg" {
            let planned = try #require(MeasureAccidentals.plannedPitch(
                forLetter: letter, nearestTo: nil, at: Self.firstSlot, in: score,
            ), "no pitch planned for \(letter) under \(clefType)")
            let step = PitchStaffPosition.step(
                midiPitch: planned.pitch, tpc: planned.tpc, clef: clef,
            ).step
            #expect(
                (-4 ... 4).contains(step),
                "\(letter) under \(clefType) landed at step \(step) (pitch \(planned.pitch))",
            )
        }
    }

    /// The concrete case from the report, pinned so a future change to the octave search cannot quietly move it:
    /// A on a bass staff is the A in the first space, not the one three ledger lines above.
    @Test func `the letter A on a bass staff is A2, not A4`() throws {
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "a", nearestTo: nil, at: Self.firstSlot, in: Self.score(clefType: "F"),
        ))
        #expect(planned.pitch == 45)
    }

    /// A is the letter the old octave-4 default already got right on a treble staff, and it stays put. The rest of
    /// the treble row does move — see `the treble row matches MuseScore's own answers` — so this is a pin on the
    /// one case where "unchanged" is the claim, not on the clef as a whole.
    @Test func `the letter A on a treble staff is still A4`() throws {
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "a", nearestTo: nil, at: Self.firstSlot, in: Self.score(clefType: "G"),
        ))
        #expect(planned.pitch == 69)
    }

    /// An octave-transposing clef reads an octave off its parent, so the default octave has to move with it.
    @Test func `an 8vb treble staff writes an octave lower`() throws {
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "a", nearestTo: nil, at: Self.firstSlot, in: Self.score(clefType: "G8vb"),
        ))
        #expect(planned.pitch == 57)
    }

    /// A previous note still wins: the clef only supplies the anchor when nothing was played.
    @Test func `a reference note still chooses the octave`() throws {
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "a", nearestTo: 69, at: Self.firstSlot, in: Self.score(clefType: "F"),
        ))
        #expect(planned.pitch == 69)
    }

    /// Mid-score clef changes have to carry: a staff that opens in bass and drops into treble at bar 1 writes the
    /// treble octave from bar 1 on. This is why the lookup is `clefInForce(at:)` and not `authoredClef(at:)`.
    @Test func `a clef change later in the staff governs what follows it`() throws {
        var score = Self.score(clefType: "F", measureCount: 2)
        // Bar 1 of a blank score holds only its measure rest, so the clef `SetClef` puts BEFORE that rest lands at
        // element 0 and pushes the rest to element 1.
        let restInBarOne = VoiceElementID(staff: Self.staff, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        try SetClef(before: restInBarOne, clef: .treble).apply(to: &score)
        let shiftedRest = restInBarOne.withElementIndex(1)
        #expect(score.clefInForce(at: Self.firstSlot) == .bass)
        #expect(score.clefInForce(at: shiftedRest) == .treble)
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "a", nearestTo: nil, at: shiftedRest, in: score,
        ))
        #expect(planned.pitch == 69)
    }

    /// A letter exactly a tritone from the anchor takes the LOWER octave, which is MuseScore's asymmetric
    /// `delta < -6` and not the upward tie-break `nearestTo` uses.
    ///
    /// F under a treble clef is the whole case: F4 (first space) and F5 (top line) are both six semitones from
    /// B4 and both sit in the staff, so the in-staff property cannot tell them apart — only MuseScore's rule can,
    /// and it writes F4.
    @Test func `a tritone tie takes the lower octave, as MuseScore does`() throws {
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "f", nearestTo: nil, at: Self.firstSlot, in: Self.score(clefType: "G"),
        ))
        #expect(planned.pitch == 65)
    }

    /// The rest of the treble row, pinned because this is the clef the app uses most and a later change to the
    /// octave search would otherwise move it silently. C/D/E land an octave above middle C — inside the staff,
    /// where middle C's own octave was one and two ledger lines below it.
    @Test func `the treble row matches MuseScore's own answers`() throws {
        let score = Self.score(clefType: "G")
        let expected: [(Character, Int)] = [
            ("c", 72), ("d", 74), ("e", 76), ("f", 65), ("g", 67), ("a", 69), ("b", 71),
        ]
        for (letter, pitch) in expected {
            let planned = try #require(MeasureAccidentals.plannedPitch(
                forLetter: letter, nearestTo: nil, at: Self.firstSlot, in: score,
            ))
            #expect(planned.pitch == pitch, "letter \(letter)")
        }
    }

    /// An unpitched staff is out of scope — it places by drum line, not by letter — and must keep behaving exactly
    /// as it did. The percussion clefs anchor on the treble's middle line for that reason.
    @Test func `a percussion staff is unchanged`() throws {
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "a", nearestTo: nil, at: Self.firstSlot,
            in: Self.score(clefType: "PERC"),
        ))
        #expect(planned.pitch == 69)
    }
}
