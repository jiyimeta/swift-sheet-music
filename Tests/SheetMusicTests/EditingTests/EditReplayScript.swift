import Foundation
@testable import SheetMusicCore

/// One step of a scripted editing session.
enum EditReplayStep {
    case intent(EditIntent)
    case undo
    case redo
}

/// The fixed, hand-rolled sequence of edits that both `EditReplayGoldenTests` (host + device, wire bytes and
/// fingerprints) and `EditReplayDeterminismTests` (two independent host sessions) replay over
/// `EditingFixtures.replayFixture()`. One script, two consumers, so "the replay is deterministic" and "the wire
/// bytes are what a device would receive" are proven against the exact same edits rather than two scripts that
/// could quietly drift apart.
///
/// Everything here is derived from the step index — no randomness, no clock. A determinism test that is itself
/// nondeterministic proves nothing, and the same script has to be reproducible on a device months later.
///
/// ## Index stability
///
/// `VoiceElementID.elementIndex` is a raw position in a measure's element array, and several intents below change
/// how many elements a measure holds (`createTuplet` / `removeTuplet` splice `actualNotes - 1` members in or out;
/// a cross-bar `inputNote` and a bar-emptying `delete` can insert or remove trailing rests). A step that shifts an
/// index a LATER step addresses by fixed position would silently change what that later step means — the hazard
/// `EditReplayGoldenTests`' predecessor array was built around for its one measure. This script is longer and
/// touches three measures, so the same discipline is applied per measure rather than to one array:
///
/// - **Measure 0** (elements 2...5 start as: seed chord, rest, rest, rest) is addressed strictly by growing element
///   index, and only the LAST group to touch it (steps 5a/5b, `createTuplet` then `inputNote` inside it) changes its
///   element count. Steps 1-4 and 6 all target elements 2 and 3, which sit BEFORE element 4 and so are never moved
///   by what happens there. Step 7 (the cross-bar write) targets element 7 — element 5 renumbered after step 5a's
///   tuplet inserted two members at element 4 — which is only correct once step 5a has already run, exactly the
///   order this array uses. Step 9 (`removeTuplet`) removes those same two members again, but nothing after it
///   addresses measure 0 by fixed index (the tail undo/redo pair re-targets the tuplet itself, not a position past
///   it), so the shift back is safe.
/// - **Measure 1** is touched only by step 7 (the cross-bar write's tail, replacing element 0 one-for-one — the
///   armed length is beat-aligned so the splice never inserts a second piece) and step 7b (`setRestDuration`
///   shortening element 3, which inserts a new trailing rest at element 4 that nothing else ever addresses).
///   Independent of measure 0's index gymnastics entirely, since element indices never cross a measure boundary.
/// - **Measure 2** is touched only by steps 8a/8b: shortening the seeded chord at element 1 (which inserts a
///   trailing rest after it, at element 2 — again unreferenced elsewhere) and then deleting that SAME element 1,
///   which collapses the whole bar to a single measure rest. The shrink doesn't move element 1 itself, so the
///   delete that follows still finds the chord it expects.
///
/// ## Undo / redo
///
/// The device-side harness (`EditSessionReplayTest.kt`) tells an edit step from an undo step by asset presence —
/// see `EditReplayGoldenTests`' doc comment — so a genuine `nativeEditRedo` call has no wire representation to
/// commit here without a second harness convention. This script gets the same observable effect by re-applying the
/// undone intent: undo, then apply the identical `EditIntent` bytes again. Both sides see an ordinary
/// apply-or-undo step, so "redo" needs no new convention while still exercising an undo immediately followed by
/// the state it undid coming back.
enum EditReplayScript {
    /// Fourteen steps over `EditingFixtures.replayFixture()`, covering every `EditIntent` case (see this type's doc
    /// comment for the index-stability argument behind their ordering).
    static func standard(staff: StaffAddress) -> [EditReplayStep] {
        func rest(_ measure: Int, _ element: Int) -> RestID {
            RestID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
        }
        func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
            VoiceElementID(rest(measure, element))
        }
        func note(_ measure: Int, _ element: Int, _ noteIndex: Int) -> NoteID {
            NoteID(
                staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: noteIndex,
            )
        }

        // Step 1: write C# — the letter D major alters — into the rest at measure 0 element 3. The seed chord at
        // element 2 (C natural) is already "in force" earlier in the bar, so this note needs an explicit sharp, and
        // the bundled accidental repair also gives the seed itself the natural sign it never had (the repair path).
        let step1 = EditReplayStep.intent(.inputNote(at: rest(0, 3), pitch: 61, tpc: 21, duration: nil))
        // Step 2: retune that same note down to C natural with an EXPLICIT accidental — the repair path from the
        // other side: the glyph is stated by the intent itself rather than inferred, and since the seed at element 2
        // already put "natural" in force on this line, the bundled repair pass silently agrees rather than fighting it.
        let step2 = EditReplayStep.intent(.setNotePitch(at: note(0, 3, 0), pitch: 60, tpc: 14, accidental: .natural))
        // Step 3: clear the accidental again. By now the glyph the repair pass wants is already absent (step 2's
        // explicit natural was redundant given the seed and got stripped), so this is a genuine no-op SetAccidental
        // — still a real wire pin, and a legitimate "clearing it again" rather than a contrived one.
        let step3 = EditReplayStep.intent(.setAccidental(at: note(0, 3, 0), accidental: nil))
        // Step 4: add a note to that chord, then remove it, as ONE undo step — exercises addNoteToChord,
        // removeNoteFromChord, AND the composite wire case together, reusing the chord steps 1-3 already built
        // rather than needing a third seed.
        let step4 = EditReplayStep.intent(.composite([
            .addNoteToChord(at: slot(0, 3), pitch: 64, tpc: 18, accidental: nil),
            .removeNoteFromChord(at: note(0, 3, 1)),
        ]))
        // Step 5a: turn the quarter rest at measure 0 element 4 into an eighth-note triplet (3 members at 4...6).
        let step5a = EditReplayStep.intent(.createTuplet(at: slot(0, 4), actualNotes: 3, normalNotes: 2))
        // Step 5b: write into the SECOND triplet member with an explicit (mismatched) armed duration. Before SP1
        // this refusal-prone length change would have taken the whole write down with it; `ScoreEditSession` now
        // detects the target sits inside a tuplet and writes at the slot's own length instead of refusing.
        let step5b = EditReplayStep.intent(.inputNote(at: rest(0, 5), pitch: 67, tpc: 15, duration: .eighth))
        // Step 6: tie the seed (element 2) forward into element 3 — both are C4 by now, adjacent, same voice.
        // Neither index sits inside the tuplet steps 5a/5b just built at elements 4...6, so this is unaffected by it.
        let step6 = EditReplayStep.intent(
            .setTie(from: note(0, 2, 0), to: note(0, 3, 0), sourceTieForward: 1, targetTieBack: 1),
        )
        // Step 7: an armed half note at measure 0 element 7 (element 5 renumbered by step 5a's +2) has only one
        // beat of room left in the bar, so `CrossBarInputPlanner` must intercept it and chain a tied piece into
        // measure 1 rather than let `SetRestDuration` refuse the whole write.
        let step7 = EditReplayStep.intent(.inputNote(at: rest(0, 7), pitch: 69, tpc: 17, duration: .half))
        // Step 7b: shorten measure 1's last untouched rest — a plain setRestDuration wire pin, in a measure whose
        // other elements no later step ever addresses.
        let step7b = EditReplayStep.intent(.setRestDuration(at: slot(1, 3), duration: .eighth))
        // Step 8a: shorten measure 2's seeded chord — a setChordDuration wire pin — before deleting it. The shrink
        // inserts a trailing rest AFTER element 1, so element 1 itself, which step 8b targets next, doesn't move.
        let step8a = EditReplayStep.intent(.setChordDuration(at: slot(2, 1), duration: .eighth))
        // Step 8b: delete that same chord. It was the only non-rest content left in measure 2, so this collapses
        // the whole bar to a single measure rest (`FullMeasureRestCollapse`) rather than leaving a hole.
        let step8b = EditReplayStep.intent(.delete(at: slot(2, 1)))
        // Step 9: remove the tuplet steps 5a/5b built. `RemoveTuplet` keeps the first member WITH notes as the
        // replacement content, so this collapses back to a single G4 quarter (step 5b's write), not silence.
        let step9 = EditReplayStep.intent(.removeTuplet(at: slot(0, 4)))
        // Step 10: undo step 9 (the tuplet reappears), then re-apply the identical intent — an undo immediately
        // followed by what is functionally its redo, using only the apply/undo primitives the device already
        // speaks. Nothing after this pair addresses measure 0 by fixed index, so the tuplet's element count
        // changing and changing back again is safe.
        let step10Undo = EditReplayStep.undo
        let step10Redo = EditReplayStep.intent(.removeTuplet(at: slot(0, 4)))

        return [
            step1, step2, step3, step4, step5a, step5b, step6, step7, step7b, step8a, step8b, step9, step10Undo,
            step10Redo,
        ]
    }

    /// Runs `steps` against a session seeded with `score` and returns the fingerprint after each step. The initial
    /// fingerprint is element 0, so the array is `steps.count + 1` long.
    static func fingerprints(of steps: [EditReplayStep], startingFrom score: Score) -> [Int64] {
        let session = ScoreEditSession(score: score)
        var out = [session.score.stableFingerprint]
        for step in steps {
            switch step {
            case let .intent(intent): _ = session.apply(intent)
            case .undo: _ = session.undo()
            case .redo: _ = session.redo()
            }
            out.append(session.score.stableFingerprint)
        }
        return out
    }
}
