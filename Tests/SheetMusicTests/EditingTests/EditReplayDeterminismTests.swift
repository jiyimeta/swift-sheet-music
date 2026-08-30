import Foundation
@testable import SheetMusicCore
import Testing

@Suite("Edit replay determinism")
struct EditReplayDeterminismTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test("two sessions fed the same steps agree at every step")
    func twoSessionsAgree() {
        let steps = EditReplayScript.standard(staff: Self.staff)
        let a = EditReplayScript.fingerprints(of: steps, startingFrom: EditingFixtures.replayFixture())
        let b = EditReplayScript.fingerprints(of: steps, startingFrom: EditingFixtures.replayFixture())
        #expect(a == b)
        #expect(a.count == steps.count + 1)
    }

    @Test("the script actually edits something")
    func scriptIsNotInert() {
        let prints = EditReplayScript.fingerprints(
            of: EditReplayScript.standard(staff: Self.staff), startingFrom: EditingFixtures.replayFixture(),
        )
        #expect(prints.last != prints.first)
        // A script every step of which got refused would produce a flat, single-valued fingerprint sequence and
        // "prove" determinism trivially — this rules that out by requiring real spread across the run.
        #expect(Set(prints).count >= 10)
    }

    /// The M3 meter step exists to exercise a RE-BAR, not a restated glyph, and the sharpest evidence of one is a
    /// note the new barlines CUT. Pinned here rather than left to the fingerprint chain: a fingerprint only ever
    /// proves the two images agree, never that a step did the thing it was added for. If a future planner change
    /// stops splitting here, `EditReplayScript`'s step 12a quietly decays into a re-partition of rests — and this
    /// is what says so.
    @Test("the script's 3/16 change actually cuts a note across a new barline")
    func timeSignatureStepSplitsANote() {
        let steps = EditReplayScript.standard(staff: Self.staff)
        guard let changeIndex = steps.firstIndex(where: { step in
            guard case let .intent(intent) = step, case .setTimeSignature = intent else { return false }
            return true
        }), case let .intent(change) = steps[changeIndex] else {
            Issue.record("the script no longer contains a setTimeSignature step")
            return
        }

        let session = ScoreEditSession(score: EditingFixtures.replayFixture())
        func measures() -> [Measure] {
            session.score.parts[0].staves[0].measures
        }
        func firstNotedChord(inMeasure index: Int) -> Chord? {
            for element in measures()[index].voices[0].elements {
                if case let .chord(chord) = element, !chord.notes.isEmpty { return chord }
            }
            return nil
        }

        for step in steps[..<changeIndex] {
            switch step {
            case let .intent(intent): _ = session.apply(intent)
            case .undo: _ = session.undo()
            case .redo: _ = session.redo()
            }
        }
        // Measure 1 opens on a whole quarter, tied back from measure 0 but not forward to anything.
        let before = firstNotedChord(inMeasure: 1)
        #expect(before?.duration == .quarter)
        #expect(before?.notes.isEmpty == false)
        #expect(before?.notes[0].tieForward == nil)
        let barsBefore = measures().count

        #expect(session.apply(change))

        // Four sixteenths do not fit the three-sixteenth bar they now open, so the quarter comes back as an eighth
        // plus a sixteenth filling the new measure 1, tied on into a sixteenth opening measure 2.
        let head = firstNotedChord(inMeasure: 1)
        #expect(head?.duration == .eighth)
        #expect(head?.notes.isEmpty == false)
        #expect(head?.notes[0].tieForward != nil)
        let carried = firstNotedChord(inMeasure: 2)
        #expect(carried?.duration == .sixteenth)
        #expect(carried?.notes.isEmpty == false)
        #expect(carried?.notes[0].tieBack != nil)
        #expect(measures().count > barsBefore)
    }
}
