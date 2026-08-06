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
}
