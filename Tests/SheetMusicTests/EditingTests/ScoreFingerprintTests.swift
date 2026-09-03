@testable import SheetMusicCore
import Testing

@Suite("Score.stableFingerprint")
struct ScoreFingerprintTests {
    private static let restAt1 = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )

    @Test("equal scores fingerprint equally")
    func equalScoresAgree() {
        let a = EditingFixtures.fourQuarterRests()
        let b = EditingFixtures.fourQuarterRests()
        #expect(a.stableFingerprint == b.stableFingerprint)
    }

    @Test("a written note changes the fingerprint")
    func editChangesFingerprint() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        _ = try InputNote(at: Self.restAt1, pitch: 60, tpc: 14).apply(to: &score)
        #expect(score.stableFingerprint != before)
    }

    @Test("undoing an edit restores the fingerprint")
    func undoRestoresFingerprint() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        let inverse = try InputNote(at: Self.restAt1, pitch: 60, tpc: 14).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score.stableFingerprint == before)
    }

    @Test("pitch and spelling are both in the hash")
    func pitchAndSpellingCount() throws {
        var sharp = EditingFixtures.fourQuarterRests()
        var flat = EditingFixtures.fourQuarterRests()
        _ = try InputNote(at: Self.restAt1, pitch: 61, tpc: 21).apply(to: &sharp) // C#
        _ = try InputNote(at: Self.restAt1, pitch: 61, tpc: 9).apply(to: &flat) // Db
        #expect(sharp.stableFingerprint != flat.stableFingerprint)
    }

    @Test("the fingerprint is stable across repeated reads")
    func repeatedReadsAgree() {
        let score = EditingFixtures.fourQuarterRests()
        let first = score.stableFingerprint
        let second = score.stableFingerprint
        #expect(first == second)
    }

    // MARK: - Fields a planner's element copy carries (Task 6)

    @Test("an articulation change moves the fingerprint")
    func articulationChangeMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.articulations.append(ChordArticulation(kind: .unknown(subtype: "articStaccatoAbove")))
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("a notehead change moves the fingerprint")
    func noteheadChangeMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].headType = "cross"
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("an arpeggio moves the fingerprint")
    func arpeggioMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.arpeggio = Arpeggio(subtype: 1)
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("a lyric moves the fingerprint")
    func lyricMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.lyrics.append(Lyric(text: "la"))
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("a grace note's own pitch moves the fingerprint, not just its count")
    func graceNoteContentMovesFingerprint() {
        var withC = EditingFixtures.chordAtIndex1()
        var withD = EditingFixtures.chordAtIndex1()
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chordC) = withC[slot], case var .chord(chordD) = withD[slot] else {
            Issue.record("expected a chord"); return
        }
        chordC.graceNotesBefore = [GraceChord(graceType: .acciaccatura, duration: .sixteenth, notes: [
            Note(pitch: 60, tpc: 14),
        ])]
        chordD.graceNotesBefore = [GraceChord(graceType: .acciaccatura, duration: .sixteenth, notes: [
            Note(pitch: 62, tpc: 16),
        ])]
        withC[slot] = .chord(chordC)
        withD[slot] = .chord(chordD)
        #expect(withC.stableFingerprint != withD.stableFingerprint)
    }

    @Test("a trailing grace note's own pitch moves the fingerprint, not just its count")
    func graceNoteAfterContentMovesFingerprint() {
        var withC = EditingFixtures.chordAtIndex1()
        var withD = EditingFixtures.chordAtIndex1()
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chordC) = withC[slot], case var .chord(chordD) = withD[slot] else {
            Issue.record("expected a chord"); return
        }
        chordC.graceNotesAfter = [GraceChord(graceType: .grace16after, duration: .sixteenth, notes: [
            Note(pitch: 60, tpc: 14),
        ])]
        chordD.graceNotesAfter = [GraceChord(graceType: .grace16after, duration: .sixteenth, notes: [
            Note(pitch: 62, tpc: 16),
        ])]
        withC[slot] = .chord(chordC)
        withD[slot] = .chord(chordD)
        #expect(withC.stableFingerprint != withD.stableFingerprint)
    }

    @Test("a tremolo moves the fingerprint")
    func tremoloMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.tremolo = Tremolo(subtype: .r16)
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("a chord line moves the fingerprint")
    func chordLineMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.chordLines.append(ChordLine(kind: .fall))
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("stem and beam visibility move the fingerprint")
    func stemAndBeamVisibilityMoveFingerprint() {
        var stemHidden = EditingFixtures.chordAtIndex1()
        var beamHidden = EditingFixtures.chordAtIndex1()
        let baseline = EditingFixtures.chordAtIndex1().stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(stemChord) = stemHidden[slot], case var .chord(beamChord) = beamHidden[slot] else {
            Issue.record("expected a chord"); return
        }
        stemChord.stemVisible = false
        beamChord.beamVisible = false
        stemHidden[slot] = .chord(stemChord)
        beamHidden[slot] = .chord(beamChord)
        #expect(stemHidden.stableFingerprint != baseline)
        #expect(beamHidden.stableFingerprint != baseline)
        #expect(stemHidden.stableFingerprint != beamHidden.stableFingerprint)
    }

    @Test("an accidental bracket change moves the fingerprint")
    func accidentalBracketChangeMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].accidentalBracket = .parenthesis
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("an accidental role change moves the fingerprint")
    func accidentalRoleChangeMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].accidentalRole = .user
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("a glissando moves the fingerprint")
    func glissandoMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].glissando = Glissando(style: .chromatic)
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("note parentheses change the fingerprint")
    func parenthesesChangeMovesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].parentheses = .both
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("isSmall changes the fingerprint")
    func isSmallChangesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].isSmall = true
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("play changes the fingerprint")
    func playChangesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].play = false
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test("note visibility changes the fingerprint")
    func noteVisibilityChangesFingerprint() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.notes[0].visible = false
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    // MARK: - Measure irregularity and the system lane (M3)

    @Test("a measure's actualLength is in the hash")
    func actualLengthMovesFingerprint() {
        let nominal = EditingFixtures.fourQuarterRests()
        var pickup = EditingFixtures.fourQuarterRests()
        pickup.parts[0].staves[0].measures[0].actualLength = Fraction(numerator: 1, denominator: 4)
        #expect(nominal.stableFingerprint != pickup.stableFingerprint)
    }

    @Test("a measure's irregular flag is in the hash")
    func irregularMovesFingerprint() {
        let counted = EditingFixtures.fourQuarterRests()
        var uncounted = EditingFixtures.fourQuarterRests()
        uncounted.parts[0].staves[0].measures[0].irregular = true
        #expect(counted.stableFingerprint != uncounted.stableFingerprint)
    }

    @Test("a system-lane element is in the hash")
    func systemMeasureElementMovesFingerprint() {
        var markedA = EditingFixtures.fourQuarterRests()
        var markedB = EditingFixtures.fourQuarterRests()
        markedA.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: "A"))),
        ])]
        markedB.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: "B"))),
        ])]
        #expect(markedA.stableFingerprint != markedB.stableFingerprint)
    }

    // MARK: - Chord-anchored spanners (Task 2, group 6)

    private static func slurred(_ score: Score) -> Score {
        var score = score
        guard case var .chord(chord) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            return score
        }
        chord.spanners = [Spanner(
            kind: .slur, rawType: "Slur",
            nextMeasuresOffset: 0, nextFractionsOffset: Fraction(numerator: 1, denominator: 2),
        )]
        score.parts[0].staves[0].measures[0].voices[0].elements[1] = .chord(chord)
        return score
    }

    /// The by-occupants half of the §2.5 rule, and the reason every committed golden survives this change: a
    /// score whose chords carry no spanner must hash to what it hashed BEFORE `Chord.spanners` entered the walk.
    /// The literal is the value `EditingFixtures.parityFixture()` produced on `main` at the time this landed —
    /// re-read it from the failing test's output, do not invent it, and never "update" it to make a later change
    /// pass (that is exactly the regression this pin exists to catch).
    @Test("a score with no chord-anchored spanner hashes as it did before spanners entered the walk")
    func defaultsHashUnchanged() {
        #expect(EditingFixtures.parityFixture().stableFingerprint == 7_849_725_953_743_034_330)
        #expect(EditingFixtures.replayFixture().stableFingerprint == 5_905_105_043_072_328_748)
    }

    @Test("adding a chord-anchored slur moves the fingerprint; removing it restores the old value")
    func slurIsVisible() {
        let plain = EditingFixtures.parityFixture()
        let withSlur = Self.slurred(plain)
        #expect(withSlur.stableFingerprint != plain.stableFingerprint)
        var restored = withSlur
        guard case var .chord(chord) = restored.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the chord"); return
        }
        chord.spanners = []
        restored.parts[0].staves[0].measures[0].voices[0].elements[1] = .chord(chord)
        #expect(restored.stableFingerprint == plain.stableFingerprint)
    }

    @Test("two chord-anchored spanners that differ only in their end offsets hash differently")
    func offsetsAreVisible() {
        var a = Self.slurred(EditingFixtures.parityFixture())
        guard case var .chord(chord) = a.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the chord"); return
        }
        let b = a
        chord.spanners[0].nextFractionsOffset = Fraction(numerator: 1, denominator: 4)
        a.parts[0].staves[0].measures[0].voices[0].elements[1] = .chord(chord)
        #expect(a.stableFingerprint != b.stableFingerprint)
    }

    @Test("the same slur on a different chord hashes differently")
    func positionIsVisible() {
        var moved = EditingFixtures.parityFixture()
        guard case var .chord(chord) = moved.parts[0].staves[0].measures[0].voices[0].elements[2] else {
            Issue.record("expected the second chord"); return
        }
        chord.spanners = [Spanner(
            kind: .slur, rawType: "Slur",
            nextMeasuresOffset: 0, nextFractionsOffset: Fraction(numerator: 1, denominator: 2),
        )]
        moved.parts[0].staves[0].measures[0].voices[0].elements[2] = .chord(chord)
        #expect(moved.stableFingerprint != Self.slurred(EditingFixtures.parityFixture()).stableFingerprint)
    }
}
