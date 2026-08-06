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
}
