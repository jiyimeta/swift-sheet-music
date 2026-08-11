@testable import SheetMusicCore
import Testing

@Suite("ScoreEditSession")
struct ScoreEditSessionTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let restAt1 = RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let slotAt1 = VoiceElementID(restAt1)

    @Test("inputNote writes a chord into the slot")
    func inputNoteWrites() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        guard case .chord = session.score[Self.slotAt1] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(session.lastAffectedLocation == Self.slotAt1)
    }

    @Test("inputNote with a duration retimes the slot in the same undo step")
    func inputNoteWithDurationIsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: .half)))
        guard case let .chord(chord) = session.score[Self.slotAt1] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(chord.duration == .half)
        #expect(session.undo())
        #expect(session.canUndo == false) // one step, not two
    }

    @Test("a refused intent leaves the score untouched and reports false")
    func refusedIntentIsANoOp() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let before = session.score.stableFingerprint
        let outOfRange = VoiceElementID(staff: Self.staff, measureIndex: 99, voiceIndex: 0, elementIndex: 0)
        #expect(session.apply(.delete(at: outOfRange)) == false)
        #expect(session.score.stableFingerprint == before)
        #expect(session.canUndo == false)
    }

    @Test("a refusal's reason is captured, and a later success clears it")
    func lastRefusalReasonTracksApplyOutcome() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.lastRefusalReason == nil)
        let outOfRange = VoiceElementID(staff: Self.staff, measureIndex: 99, voiceIndex: 0, elementIndex: 0)
        #expect(session.apply(.delete(at: outOfRange)) == false)
        #expect(session.lastRefusalReason?.contains("DeleteVoiceElement") == true)
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        #expect(session.lastRefusalReason == nil)
    }

    /// Mirrors `EditIntentCodecTests.deeplyNestedCompositeThrows` at the domain layer rather than the wire layer:
    /// `command(for:in:depth:)` recurses on `.composite` with no bound of its own, and a malformed or pathological
    /// intent tree — however it got constructed — must be refused before it can overflow the stack.
    @Test("a composite nested past the depth limit is refused, not stack-overflowed")
    func deeplyNestedCompositeIsRefused() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        var intent = EditIntent.delete(at: Self.slotAt1)
        for _ in 0 ..< 20 {
            intent = .composite([intent])
        }
        #expect(session.apply(intent) == false)
        #expect(session.lastRefusalReason?.contains("depth limit") == true)
    }

    @Test("composite applies as one undo step")
    func compositeIsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let before = session.score.stableFingerprint
        #expect(session.apply(.composite([
            .inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil),
            .setChordDuration(at: Self.slotAt1, duration: .half),
        ])))
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    @Test("undo then redo returns to the edited fingerprint")
    func undoRedoRoundTrips() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        let edited = session.score.stableFingerprint
        #expect(session.undo())
        #expect(session.redo())
        #expect(session.score.stableFingerprint == edited)
    }

    @Test("undo on an empty stack reports false rather than throwing")
    func undoOnEmptyStack() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.undo() == false)
        #expect(session.redo() == false)
    }

    @Test("inputNote inside a tuplet ignores the requested duration but still writes the note")
    func inputNoteInsideTupletIgnoresDuration() throws {
        // Build a triplet across elements 2..4 (three quarter-rests worth of ticks split into thirds), then
        // ask for a note at the tuplet's first member with a duration that the engine would otherwise honor
        // outside a tuplet. The refused length change must not take the note write down with it.
        var score = EditingFixtures.fourQuarterRests()
        let tupletTarget = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        _ = try CreateTuplet(at: tupletTarget, actualNotes: 3, normalNotes: 2).apply(to: &score)
        let memberDuration = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))

        let session = ScoreEditSession(score: score)
        let restInTuplet = RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        let slotInTuplet = VoiceElementID(restInTuplet)
        #expect(session.apply(.inputNote(at: restInTuplet, pitch: 60, tpc: 14, duration: .half)))
        guard case let .chord(chord) = session.score[slotInTuplet] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(chord.duration == memberDuration) // the requested .half was refused and dropped, not honored
        #expect(!chord.notes.isEmpty)
        #expect(session.undo())
        #expect(session.canUndo == false) // one step, even though the plan considered two commands
    }

    /// A half note armed on the last quarter of a 4/4 bar. Without the cross-bar interception the composite's
    /// SetRestDuration is refused and takes the note write down with it, so nothing appears at all.
    @Test func `an overrunning duration still writes the note`() throws {
        let session = ScoreEditSession(score: EditingFixtures.twoMeasuresOfQuarterRests())
        let target = EditingFixtures.restID(element: 4)
        #expect(session.apply(.inputNote(at: target, pitch: 60, tpc: 14, duration: .half)))
        let written = try #require(session.score[VoiceElementID(target)])
        guard case let .chord(chord) = written else { Issue.record("expected a chord"); return }
        #expect(!chord.notes.isEmpty)
    }

    /// Deleting the only element of a bar leaves ONE measure rest, not an empty bar.
    @Test func `a delete that empties a bar collapses to a measure rest`() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))
        score[slot] = .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))
        score.parts[0].staves[0].measures[1].voices[0].elements.removeSubrange(1...)
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.delete(at: slot)))
        let elements = session.score.parts[0].staves[0].measures[1].voices[0].elements
        #expect(elements.count == 1)
        guard case let .chord(rest) = elements[0] else { Issue.record("expected a rest"); return }
        #expect(rest.notes.isEmpty)
        #expect(rest.duration == .measure)
    }

    /// The rest the collapse writes is not always at element index 0 — a leading time signature stays put and the
    /// rest lands after it. `ReplaceVoiceElements.affectedLocation` always reports element 0, which is exactly why
    /// `FullMeasureRestCollapse.Plan` hands back `restElementIndex` separately: `lastAffectedLocation` has to be
    /// built from that, not trusted to the underlying command's own report.
    @Test func `a bar-emptying delete lands the selection on the new rest, not element 0`() {
        var score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.delete(at: slot)))
        #expect(session.lastAffectedLocation == VoiceElementID(
            staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        ))
        let elements = session.score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements.count == 2) // the leading time signature, then one measure rest
        guard case let .chord(rest) = elements[1] else { Issue.record("expected a rest"); return }
        #expect(rest.notes.isEmpty)
        #expect(rest.duration == .measure)
    }

    /// A rest re-timed to fill its bar from beat one is spelled `.measure`, mirroring the delete-side collapse from
    /// the other direction: there a bar EMPTIES into one, here a bar is FILLED with one.
    @Test func `setRestDuration promotes a bar-filling rest to the measure spelling`() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let target = VoiceElementID(EditingFixtures.restID(element: 1))
        #expect(session.apply(.setRestDuration(at: target, duration: .whole)))
        guard case let .chord(rest) = session.score[target] else { Issue.record("expected a rest"); return }
        #expect(rest.duration == .measure)
    }

    /// A rest re-timed to less than its bar keeps the literal duration it was asked for — the promotion is only for
    /// the length that actually fills the bar.
    @Test func `setRestDuration keeps a partial-bar rest as the literal duration`() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let target = VoiceElementID(EditingFixtures.restID(element: 1))
        #expect(session.apply(.setRestDuration(at: target, duration: .half)))
        guard case let .chord(rest) = session.score[target] else { Issue.record("expected a rest"); return }
        #expect(rest.duration == .half)
    }

    // MARK: - SP1: the remaining intents

    /// A malformed tuplet ratio must be REFUSED, not trapped. CreateTuplet's init preconditions are traps, so a
    /// wire payload carrying 0 would kill the process on a path this API advertises as returning false.
    @Test func `a degenerate tuplet ratio is refused, not trapped`() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        #expect(!session.apply(.createTuplet(at: slot, actualNotes: 1, normalNotes: 2)))
        #expect(!session.apply(.createTuplet(at: slot, actualNotes: 3, normalNotes: 0)))
        #expect(session.lastRefusalReason != nil)
    }

    @Test func `a pitch change lands and undoes`() throws {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let note = EditingFixtures.noteID(element: 1)
        let before = session.score.stableFingerprint
        #expect(session.apply(.setNotePitch(at: note, pitch: 62, tpc: 16, accidental: nil)))
        #expect(try #require(session.score[note]).pitch == 62)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    /// Flipping a bar's first C# to C natural leaves the bar's second C# reading natural unless the engine repairs
    /// it — carried forward from Task 2, which deferred it here because it needs `.setNotePitch`. This is the only
    /// test in the branch that reaches `renotatingAccidentals`'s `!repairs.isEmpty` path: the second note's stored
    /// accidental is asserted directly (not just the fingerprint) so a passing run is proof the repair actually
    /// landed, not a coincidental fingerprint change from the pitch edit alone. The repairs ride the same undo step,
    /// so ONE undo puts both notes back.
    @Test func `accidental repairs ride the same undo step`() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        let second = VoiceElementID(EditingFixtures.restID(element: 3))
        score[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        score[second] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        let session = ScoreEditSession(score: score)
        let before = session.score.stableFingerprint
        let secondNote = EditingFixtures.noteID(element: 3)
        #expect(try #require(session.score[secondNote]).accidental == nil) // sharp is implied by the key, unwritten
        #expect(session.apply(.setNotePitch(
            at: EditingFixtures.noteID(element: 2), pitch: 72, tpc: 14, accidental: .natural,
        )))
        // The repair: the second C# now carries an explicit sharp, so it still reads as sharp even though the first
        // note's new natural would otherwise leave that reading in force for the rest of the bar.
        #expect(try #require(session.score[secondNote]).accidental == .sharp)
        #expect(session.score.stableFingerprint != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    @Test func `setAccidental respells the note`() throws {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let note = EditingFixtures.noteID(element: 1)
        #expect(session.apply(.setAccidental(at: note, accidental: .sharp)))
        let written = try #require(session.score[note])
        #expect(written.pitch == 61)
        #expect(written.accidental == .sharp)
    }

    @Test func `addNoteToChord grows the chord`() {
        let session = ScoreEditSession(score: EditingFixtures.twoNoteChordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        #expect(session.apply(.addNoteToChord(at: slot, pitch: 67, tpc: 15, accidental: nil)))
        guard case let .chord(chord) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(chord.notes.count == 3)
    }

    @Test func `removeNoteFromChord shrinks the chord`() {
        let session = ScoreEditSession(score: EditingFixtures.twoNoteChordAtIndex1())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        let note = EditingFixtures.noteID(element: 1, noteIndex: 1)
        #expect(session.apply(.removeNoteFromChord(at: note)))
        guard case let .chord(chord) = session.score[slot] else { Issue.record("expected a chord"); return }
        #expect(chord.notes.count == 1)
    }

    @Test func `setTie ties two notes`() throws {
        let session = ScoreEditSession(score: EditingFixtures.twoConsecutiveC4Chords())
        let source = EditingFixtures.noteID(element: 1)
        let target = EditingFixtures.noteID(element: 2)
        #expect(session.apply(.setTie(from: source, to: target, sourceTieForward: 1, targetTieBack: 1)))
        #expect(try #require(session.score[source]).tieForward == 1)
    }

    @Test func `removeTuplet collapses the tuplet back to a single element`() throws {
        var score = EditingFixtures.fourQuarterRests()
        let tupletTarget = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        _ = try CreateTuplet(at: tupletTarget, actualNotes: 3, normalNotes: 2).apply(to: &score)
        let session = ScoreEditSession(score: score)
        #expect(!session.score.parts[0].staves[0].measures[0].voices[0].tuplets.isEmpty)
        #expect(session.apply(.removeTuplet(at: tupletTarget)))
        #expect(session.score.parts[0].staves[0].measures[0].voices[0].tuplets.isEmpty)
    }

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
        #expect(session.lastRefusalReason != nil)
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
}
