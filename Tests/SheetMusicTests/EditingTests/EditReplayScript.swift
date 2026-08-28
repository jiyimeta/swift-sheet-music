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
/// - **The M3 signature steps (11a-12b) address a MEASURE, never an element**, so none of the above applies to
///   them — but they move the ground under anything that would. Step 11a inserts a key signature at the head of
///   measure 1, shifting every element index in that bar by one; steps 12a/12b re-bar measures 1 onward and change
///   how many measures the score even has (three bars, then twelve, then four). They come after everything that
///   addresses an ELEMENT for exactly that reason: nothing past them names a slot by fixed position.
/// - **The M4 rehearsal-mark steps (13a/13b) address a measure too**, and are the only steps that run after the
///   re-bar. Measure 1 is a safe target for them because 12b settles the score at four measures — one MORE than it
///   started with, never fewer — so the bar they name exists whatever the re-bar did to the ones around it.
///
/// ## Identical fingerprints are not redundant steps
///
/// Step 3 (`setAccidental`, a genuine no-op glyph clear) and step 4 (`addNoteToChord` +
/// `removeNoteFromChord` bundled as one `composite`, which nets back to the chord it started from) both
/// correctly leave the fingerprint unchanged from the step before them — three consecutive identical values
/// in `goldens.txt`. That is NOT a sign these steps could be dropped: the fingerprint only ever proves the
/// two mirrored scores still agree, not that the step under test actually ran. What distinguishes a step
/// that legitimately changed nothing from one that silently failed is `EditSessionReplayTest.kt` asserting
/// each `nativeApplyEditIntent` call returned `true` — drop that boolean assertion and a future edit here
/// that starts refusing silently would still pass on fingerprints alone.
///
/// Step 13b is the same situation reached from the other direction: rather than repeating its neighbor it lands
/// back on step 12b's value, because the system lane is hashed by its occupants and the mark it removed is the only
/// occupant either step ever put there. Same guard, same reason it is not droppable — it is the only step in this
/// script that encodes `removeRehearsalMark`'s wire bytes at all.
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
    /// Twenty steps over `EditingFixtures.replayFixture()` (see this type's doc comment for the index-stability
    /// argument behind their ordering).
    ///
    /// Covers every `EditIntent` case that names a slot or a bar: the SP0/SP1/SP2 note and slot intents, plus M3's
    /// four signature intents and M4's two rehearsal-mark intents. The M1/M2 structural intents (`insertMeasure`,
    /// `deleteMeasure`, `addPart`, `removePart`, `movePart`) are still not scripted here — they have their own
    /// command-level tests, and adding them would renumber every measure and staff index the steps below address.
    static func standard(staff: StaffAddress) -> [EditReplayStep] { // swiftlint:disable:this function_body_length
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
        // Step 11a: declare E-flat major at measure 1. The fixture is in D major, so this is a real change of key
        // rather than a restatement: it inserts a key signature at the head of a bar that carried none, and the
        // planner re-spells the span it governs (measures 1 onward) against the new key.
        let step11a = EditReplayStep.intent(.setKeySignature(measureIndex: 1, concertKey: -3))
        // Step 11b: take it away again, so the span falls back to the D major measure 0 still declares. Paired with
        // 11a deliberately: `RemoveKeySignature` has a pre-image inverse of its own, and a script that only ever
        // set a key would never encode the removal's wire bytes at all.
        let step11b = EditReplayStep.intent(.removeKeySignature(measureIndex: 1))
        // Step 12a: 3/16 at measure 1 — a real RE-BAR, not just a glyph swap. The region (measures 1...2, since no
        // later bar declares its own meter) holds eight quarters, which re-partition into eleven bars of three
        // sixteenths, and the A4 quarter at the head of measure 1 — four sixteenths long, in a bar only three wide —
        // is CUT by the first new barline: it comes back as an eighth plus a sixteenth filling the new measure 1,
        // tied on into a sixteenth opening measure 2. A meter whose bar is at least a quarter long would have left
        // every note whole and exercised only the re-partition, so the denominator is 16 on purpose.
        let step12a = EditReplayStep.intent(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 16))
        // Step 12b: remove it, re-barring the same span back to the 4/4 measure 0 declares. NOT an arithmetic undo
        // of 12a and deliberately so: 12a's last bar was padded to a full 3/16, so the span comes back one sixteenth
        // longer than it went in and the score settles at four measures rather than the three it started with. This
        // is the removal's own re-bar path, reached through its own wire bytes.
        let step12b = EditReplayStep.intent(.removeTimeSignature(measureIndex: 1))
        // Step 13a: name measure 1 "A". A rehearsal mark is the first SYSTEM-lane edit in this script — every step
        // above it moves voice elements — so it is also the first one whose wire bytes carry a string, and the
        // first whose fingerprint moves through `combineSystemLane` rather than through a staff's measures. Which
        // lane it meets depends on how the fixture was spelled: the in-memory `EditingFixtures.replayFixture()`
        // that `EditReplayDeterminismTests` starts from leaves `systemMeasures` empty, so the write pads the lane
        // out to one entry per measure first, while the `fixture.mscx` `EditReplayGoldenTests` loads always decodes
        // one (empty) `SystemMeasure` per bar, where that pad is a no-op. One script over both spellings covers
        // both paths.
        let step13a = EditReplayStep.intent(.setRehearsalMark(measureIndex: 1, text: "A"))
        // Step 13b: take it away again. Paired with 13a deliberately, for the reason 11a/11b are paired:
        // `RemoveRehearsalMark` has its own inverse and its own wire bytes, and a script that only ever set a mark
        // would encode neither. It is NOT an arithmetic undo of 13a — the removal drops the mark WITHOUT
        // un-padding the lane 13a may have grown — and yet the fingerprint lands back on 12b's exactly. That is
        // correct, not a sign the step was inert: `combineSystemLane` feeds the lane by its OCCUPANTS and never by
        // its length, precisely so a padded-but-empty lane and an absent one hash alike (see `ScoreFingerprint`).
        // What proves this step ran is the same thing that proves steps 3 and 4 did — see "Identical fingerprints
        // are not redundant steps" on this type.
        let step13b = EditReplayStep.intent(.removeRehearsalMark(measureIndex: 1))

        return [
            step1, step2, step3, step4, step5a, step5b, step6, step7, step7b, step8a, step8b, step9, step10Undo,
            step10Redo, step11a, step11b, step12a, step12b, step13a, step13b,
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
