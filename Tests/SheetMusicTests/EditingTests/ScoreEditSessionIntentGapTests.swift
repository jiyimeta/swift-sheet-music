@testable import SheetMusicCore
import Testing

/// The four places SP2 found `EditIntent` saying less than the host meant, each closed by making the intent carry
/// the whole meaning rather than making the host assemble it.
///
/// They are grouped here rather than in `ScoreEditSessionTests` because they share a lesson worth keeping legible:
/// an intent that a host has to wrap in a composite to get right is an intent that will be got wrong on the other
/// platform. Each section names the composite that looks like it should work and the reason it does not.
@Suite("ScoreEditSession — the intent-vocabulary gaps")
struct ScoreEditSessionIntentGapTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    // MARK: - SP2: re-timing a chord across the barline

    /// A quarter on the last beat of a 4/4 bar, asked for a half. `SetChordDuration` alone is refused — the engine
    /// has no room to lengthen inside the bar — so without the cross-bar interception a host's length key reads as
    /// dead at every barline, the same hole `CrossBarInputPlanner` closed on the input side.
    @Test func `a chord re-timed past the barline is spelled as a tied chain`() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 4))
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.setChordDuration(at: slot, duration: .half)))

        guard case let .chord(head) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(head.duration == .quarter)
        #expect(head.notes.first?.tieForward != nil)

        let tailSlot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))
        guard case let .chord(tail) = session.score[tailSlot] else { Issue.record("expected a chord"); return }
        #expect(tail.duration == .quarter)
        #expect(tail.notes.first?.pitch == 60)
        #expect(tail.notes.first?.tieBack != nil)
    }

    /// Every note of the chord crosses, not just the lowest — the chain is planned from the chord that is actually
    /// in the slot, so a three-note chord arrives on the far side as the same three notes.
    @Test func `a re-timed chord carries all of its notes across`() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 4))
        score[slot] = .chord(Chord(duration: .quarter, notes: [
            Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18), Note(pitch: 67, tpc: 15),
        ]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.setChordDuration(at: slot, duration: .half)))

        let tailSlot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))
        guard case let .chord(tail) = session.score[tailSlot] else { Issue.record("expected a chord"); return }
        #expect(tail.notes.map(\.pitch) == [60, 64, 67])
    }

    /// The common case has to keep taking the ordinary single-slot path, so the addition above cannot have changed
    /// what already worked. `CrossBarInputPlanner.plan` returns nil for a length that fits, which is what makes this
    /// hold.
    @Test func `a chord re-timed within its bar is untouched by the cross-bar path`() {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(session.apply(.setChordDuration(at: slot, duration: .half)))

        guard case let .chord(chord) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(chord.duration == .half)
        #expect(chord.notes.first?.tieForward == nil)
    }

    // MARK: - SP2: writeNote, the letter key on an occupied slot

    /// Writing over a note is still writing a note, so the armed length has to apply too — leaving it alone would
    /// silently ignore half of what a host's pad is showing. One undo step for both halves.
    @Test func `writeNote re-pitches and re-times an occupied slot in one step`() {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .eighth)))

        guard case let .chord(chord) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(chord.duration == .eighth)
        #expect(chord.notes.count == 1)
        #expect(chord.notes.first?.pitch == 62)
        #expect(chord.notes.first?.tpc == 16)
        #expect(session.undo())
        #expect(session.canUndo == false) // one step, even though the plan considered two commands
    }

    /// The whole reason this case exists rather than a `.setChordDuration` + `.setNotePitch` composite: the chain
    /// has to carry the NEW pitch. Re-timing first and re-pitching afterwards would retune only the chain's head
    /// and leave its tail tied to it at the old pitch — a tie between two different pitches.
    @Test func `writeNote past the barline writes the new pitch into every piece`() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 4))
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .half)))

        guard case let .chord(head) = session.score[slot] else { Issue.record("expected a chord"); return }
        let tailSlot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))
        guard case let .chord(tail) = session.score[tailSlot] else { Issue.record("expected a chord"); return }
        #expect(head.notes.first?.pitch == 62)
        #expect(tail.notes.first?.pitch == 62)
        #expect(head.notes.first?.tieForward != nil)
        #expect(tail.notes.first?.tieBack != nil)
    }

    /// Inside a tuplet the member lengths are the tuplet's to decide: the engine refuses the length change, and a
    /// composite would take the pitch write down with it. Write the pitch at whatever length the slot already has —
    /// the same rule `.inputNote` follows.
    @Test func `writeNote inside a tuplet keeps the slot's own length`() throws {
        var score = EditingFixtures.chordAtIndex1()
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        _ = try CreateTuplet(at: slot, actualNotes: 3, normalNotes: 2).apply(to: &score)
        let session = ScoreEditSession(score: score)
        guard case let .chord(before) = session.score[slot] else { Issue.record("expected a chord"); return }

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .whole)))

        guard case let .chord(after) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(after.duration == before.duration)
        #expect(after.notes.first?.pitch == 62)
    }

    /// A `nil` duration means "keep the slot's length" — what a pad sends before anything is armed.
    @Test func `writeNote with no duration only re-pitches`() {
        var score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        score[slot] = .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: nil)))

        guard case let .chord(chord) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(chord.duration == .half)
        #expect(chord.notes.first?.pitch == 62)
    }

    /// A rest slot is `.inputNote`'s job. Refusing rather than quietly re-routing keeps each case telling the truth
    /// about what it means, which matters most for a relayed intent nobody is watching apply.
    @Test func `writeNote refuses a slot holding a rest`() {
        let score = EditingFixtures.fourQuarterRests()
        let session = ScoreEditSession(score: score)
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(!session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .quarter)))

        #expect(session.score == score)
        #expect(session.lastRefusal != nil)
    }

    /// The whole chain is one undo step, like every other intent.
    @Test func `undoing a cross-barline re-time puts both bars back`() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 4))
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)
        let before = session.score.stableFingerprint

        #expect(session.apply(.setChordDuration(at: slot, duration: .half)))
        #expect(session.undo())

        #expect(session.score.stableFingerprint == before)
        #expect(session.canUndo == false)
    }

    // MARK: - SP2: writeRest, the rest key over whatever is in the slot

    /// The one this case exists for. `.composite([.delete, .setRestDuration])` cannot express it: `.delete` collapses
    /// a bar it empties into a single measure rest, so the re-time would then be splicing a bar that no longer has
    /// the subdivision the caller meant to keep — the armed length is thrown away along with it.
    @Test func `writeRest over a note keeps the bar's remaining subdivision`() throws {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(session.apply(.writeRest(at: slot, duration: .half)))

        guard case let .chord(rest) = session.score[slot] else { Issue.record("expected a rest"); return }
        #expect(rest.notes.isEmpty)
        #expect(rest.duration == .half)
        // Time signature + the half + the two quarter rests the half did not reach.
        let voice = try #require(session.score[EditingFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 4)
    }

    /// Contrast with the test above: `.delete` keeps its collapse, because ⌫ means "empty this bar" rather than
    /// "make this slot this long". The two intents want opposite spellings of the same underlying delete.
    @Test func `delete still collapses the bar it empties`() throws {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(session.apply(.delete(at: slot)))

        let voice = try #require(session.score[EditingFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 2) // time signature + one measure rest
    }

    @Test func `writeRest over a rest is the plain re-time`() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(session.apply(.writeRest(at: slot, duration: .half)))

        guard case let .chord(rest) = session.score[slot] else { Issue.record("expected a rest"); return }
        #expect(rest.duration == .half)
    }

    /// A rest outlasting its bar is spelled as a run across the barline, exactly as a note is — minus the ties,
    /// which rests don't take.
    @Test func `writeRest past the barline spells a run of rests`() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 4))
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.writeRest(at: slot, duration: .half)))

        guard case let .chord(head) = session.score[slot] else { Issue.record("expected a rest"); return }
        let tailSlot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))
        guard case let .chord(tail) = session.score[tailSlot] else { Issue.record("expected a rest"); return }
        #expect(head.notes.isEmpty)
        #expect(tail.notes.isEmpty)
    }

    /// A rest filling its bar from beat one is spelled `.measure`, not the literal length — the same promotion
    /// `.setRestDuration` applies, reached from the other direction.
    @Test func `writeRest filling the bar from beat one is promoted to the measure spelling`() {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))

        #expect(session.apply(.writeRest(at: slot, duration: .whole)))

        guard case let .chord(rest) = session.score[slot] else { Issue.record("expected a rest"); return }
        #expect(rest.duration == .measure)
    }

    @Test func `writeRest on a slot holding no timed element is refused`() {
        let score = EditingFixtures.fourQuarterRests()
        let session = ScoreEditSession(score: score)
        // Element 0 is the time signature.
        let slot = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)

        #expect(!session.apply(.writeRest(at: slot, duration: .half)))

        #expect(session.score == score)
    }

    // MARK: - SP2: setNotePitch addresses the whole tie chain

    /// A tie says these noteheads are one sounding note. Retuning the named one alone leaves two pitches joined by a
    /// tie — unperformable, and `MidiRenderer` carries the head's pitch through the chain, so it would go on sounding
    /// at the old pitch under a score showing the new one.
    @Test func `setNotePitch retunes every member of the tie chain`() {
        let session = ScoreEditSession(score: EditingFixtures.tiedC4Chain(length: 3))

        #expect(session.apply(.setNotePitch(
            at: EditingFixtures.noteID(element: 2),
            pitch: 62,
            tpc: 16,
            accidental: nil,
        )))

        for element in 1 ... 3 {
            let note = session.score[EditingFixtures.noteID(element: element)]
            #expect(note?.pitch == 62)
            #expect(note?.tpc == 16)
        }
    }

    /// The chain is walked from whichever member the host named — the head, the tail, or anything between — so the
    /// result cannot depend on where the caret happened to be. Element 4 is a same-pitch neighbour the chain does not
    /// reach, and it stays put; that is what tells a chain-wide write apart from a blanket one.
    @Test func `the chain is the same whichever member is named, and stops at its own end`() {
        for named in 1 ... 3 {
            let session = ScoreEditSession(score: EditingFixtures.tiedC4Chain(length: 3))

            #expect(session.apply(.setNotePitch(
                at: EditingFixtures.noteID(element: named),
                pitch: 67,
                tpc: 15,
                accidental: nil,
            )))

            for element in 1 ... 3 {
                #expect(session.score[EditingFixtures.noteID(element: element)]?.pitch == 67)
            }
            #expect(session.score[EditingFixtures.noteID(element: 4)]?.pitch == 60)
        }
    }

    /// MuseScore prints no accidental on the far side of a tie, and `MeasureAccidentals` deliberately skips tied-back
    /// notes when it renotates a measure — so a glyph written on one here would be nobody's left to remove.
    @Test func `the accidental lands on the chain's head alone`() {
        let session = ScoreEditSession(score: EditingFixtures.tiedC4Chain(length: 3))

        #expect(session.apply(.setNotePitch(
            at: EditingFixtures.noteID(element: 3),
            pitch: 61,
            tpc: 21,
            accidental: .sharp,
        )))

        #expect(session.score[EditingFixtures.noteID(element: 1)]?.accidental == .sharp)
        #expect(session.score[EditingFixtures.noteID(element: 2)]?.accidental == nil)
        #expect(session.score[EditingFixtures.noteID(element: 3)]?.accidental == nil)
    }

    /// However many bars the chain crosses, it is one undo step — and an untied note still plans to a bare
    /// `SetNotePitch`, so the overwhelmingly common case is unchanged down to the command produced.
    @Test func `a chain-wide retune is one undo step`() {
        let session = ScoreEditSession(score: EditingFixtures.tiedC4Chain(length: 3))
        let before = session.score.stableFingerprint

        #expect(session.apply(.setNotePitch(
            at: EditingFixtures.noteID(element: 1),
            pitch: 62,
            tpc: 16,
            accidental: nil,
        )))
        #expect(session.undo())

        #expect(session.score.stableFingerprint == before)
        #expect(session.canUndo == false)
    }

    @Test func `setNotePitch on a slot holding no note is refused`() {
        let score = EditingFixtures.fourQuarterRests()
        let session = ScoreEditSession(score: score)

        #expect(!session.apply(.setNotePitch(
            at: EditingFixtures.noteID(element: 1),
            pitch: 62,
            tpc: 16,
            accidental: nil,
        )))

        #expect(session.score == score)
    }
}
