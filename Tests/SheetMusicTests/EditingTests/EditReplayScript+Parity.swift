@testable import SheetMusicCore

extension EditReplayScript {
    /// Nineteen steps over `EditingFixtures.parityFixture()`, covering every intent the edit-command parity project
    /// appended: its structural group (30…34: `setLayoutBreak`, `setBarLine`, `setRepeatBarLines`,
    /// `setMeasureRepeat`, `moveToVoice`) in steps 1…10 and its range group (35…40: `transposeRange`,
    /// `addIntervalToSelection`, `deleteRange`, `setAccidentalsInRange`, `setDurationInRange`, `respellRange`) in
    /// steps 11…19 — none of which the standard chain, which predates them, encodes at all.
    ///
    /// Each of the five structural intents appears at least twice, in both directions where it has one, so the chain
    /// pins the wire bytes of the removal as well as the write: `setLayoutBreak` on then off (steps 1 / 10),
    /// `setBarLine` `.double` then `.normal` (2 / 9), `setMeasureRepeat` grouped then dissolved (4 / 5), and
    /// `moveToVoice` applied, undone and re-applied (6 / 7 / 8). `setRepeatBarLines` (3) is the exception: it writes
    /// both flags at once, so one step already carries its whole payload, and it is left standing at the end
    /// deliberately — the final fingerprint then differs from the initial one by something no later step took back,
    /// which is what `EditReplayDeterminismTests.scriptIsNotInert` reads.
    ///
    /// The range group is spelled the same way where an intent has two directions: `transposeRange` up then down
    /// (11 / 12, the second carrying `respellInKey` — the only step that encodes that flag SET), and `deleteRange`
    /// applied, undone and re-applied (17 / 18 / 19). The other four write once each, because each already carries
    /// its whole payload in one step: an accidental (14), a spelling mode (15), a duration (16) and an interval
    /// (13) have no "off" to encode, only a different value.
    ///
    /// ## Index stability
    ///
    /// Almost every step here names a MEASURE COLUMN (`MeasureRef`) or a whole voice (`VoiceRef`), never a slot by
    /// fixed position, so the hazard this type's doc comment is largely about — an earlier step shifting an element
    /// index a later step addresses — barely applies. What could still move under a later step is spelled out per
    /// target:
    ///
    /// - **Measure 1 (steps 1, 2, 3, 9, 10)** is only ever addressed as a column. Steps 2 and 9 do change its
    ///   element count on every staff (`SetBarLine` appends a trailing `.barLine`, then `.normal` removes it
    ///   again), but no step before 16 addresses an element of measure 1 at all, on any staff, so that growth and
    ///   shrink is unobservable to the steps around it — and it is a matched pair, so measure 1's voice 0 holds
    ///   exactly the fixture's four quarter rests again by the time step 16 arrives. Steps 1/10 and 3 touch
    ///   `Measure` flags (`lineBreak`, `startRepeat` / `endRepeatCount`) rather than the element list, so they move
    ///   nothing.
    /// - **Measure 2 of the CELLO (steps 4, 5)** is the one place a step rewrites bars wholesale: step 4 turns
    ///   cello measures 2 and 3 into a measure-repeat group (a `%` sign plus a continuation rest, replacing each
    ///   bar's single measure rest) and step 5 dissolves it back. Both name the group's first bar by column and
    ///   the staff by address, and no step in this chain addresses a cello element by index, so the rewrite is
    ///   self-contained. The cello is chosen precisely because `SetMeasureRepeat` demands empty bars: measures 2
    ///   and 3 of the flute hold tied halves and a measure rest the chain must leave alone.
    /// - **Measure 0 of the FLUTE (steps 6, 8)** is the only element-level target of the structural group. Element
    ///   1 is the first C4 quarter — element 0 is the time signature, which carries no ticks — and `MoveToVoice`
    ///   replaces the source slot one-for-one with a rest of the same length, so voice 0's element count does not
    ///   change and step 8 finds exactly what step 6 did. The move's destination, voice 1 of measure 0, does not
    ///   exist yet; `MoveToVoice` creates it, splits its fresh measure rest at the 480-tick boundary and drops the
    ///   chord into the first half. Measure 0 is chosen over measure 1 — whose voice 1 the fixture already
    ///   provides — so that the create-the-voice path is the one under test; the ready-made voice 1 in measure 1
    ///   covers the other path in `MoveToVoice`'s own unit tests.
    /// - **Step 7 is the undo of step 6, and step 8 re-applies step 6's identical intent.** This is the
    ///   undo-then-reapply convention this type's "Undo / redo" section explains: `EditReplayStep.redo` has no
    ///   wire representation the device harness can commit, so a genuine redo is spelled as an undo followed by an
    ///   ordinary apply of the same bytes. Steps 9 and 10 address measure 1 only, so whatever the undo did to
    ///   measure 0's voice count cannot reach them.
    /// - **Measure 2 of the FLUTE (steps 11, 12)** holds the fixture's two tied E4 halves. `SetNotePitch` — all
    ///   `TransposeRange` plans here — changes no element count, and measure 2 of the flute is untouched by every
    ///   earlier step (step 4/5 name the CELLO's measure 2), so elements 0 and 1 are where the fixture put them.
    ///   Step 11 names only the chain's HEAD: a tie chain is one sounding note, so the whole chain follows and the
    ///   accidental lands on the head alone.
    /// - **Measure 0 of the FLUTE, element 2 (steps 13, 14, 15, 17, 19)** is the D4 at beat 2. Voice 0 reads
    ///   `[ts, r q, D4 q, r q, r q]` after step 8 — `MoveToVoice` swapped element 1 for a rest of the same
    ///   length — so element 2 is the D4 exactly as the fixture placed it, whatever step 6/8 did to voice 1.
    ///   `AddNoteToChord` (13), `SetAccidental` / `SetNotePitch` (14, 15) all leave the element count alone.
    /// - **Measure 1 of the FLUTE (step 16)** is the only step that changes an element count and is followed by
    ///   more steps: voice 0's four quarter rests become `[r h, r h]` and voice 1's measure rest is shortened too
    ///   (`Score.voiceElements(in:)` sweeps EVERY voice in the tick span, and voice 1's rest starts at tick 0,
    ///   inside it). Nothing after step 16 addresses an element of measure 1, so both count changes are
    ///   unobservable downstream.
    /// - **Step 17 empties measure 0's voice 0** — the chord becomes a rest, the voice is then all rests and
    ///   collapses to `[ts, r measure]`, 5 elements down to 2. Only steps 18 and 19 follow, and both address that
    ///   same intent: step 18 undoes it, putting the 5 elements back, and step 19 re-applies the identical bytes.
    ///   Voice 1's rest at tick 480 is inside the band and left alone (a delete of a rest is nothing to do), and
    ///   voice 1 still holds the C4 step 6/8 moved there, so it does not collapse.
    ///
    /// ## Fingerprints that repeat
    ///
    /// Every step here moves the fingerprint, but six of the recorded values REPEAT an earlier one rather than
    /// being new, and all six are correct rather than a sign of a step that did nothing: step 5 dissolves the
    /// group step 4 wrote and so lands back on step 3's value; step 7 undoes step 6 and lands back on step 5's;
    /// step 8 re-applies step 6 and lands back on step 6's; step 12 transposes back down what step 11 moved up,
    /// re-spelled to the same reading, and so lands back on step 10's; step 18 undoes step 17 and lands back on
    /// step 16's; step 19 re-applies step 17 and lands back on step 17's. Steps 9 and 10, which clear what steps 2
    /// and 1 wrote, do NOT land back on an earlier value — the repeat flags step 3 set and the voice step 6/8
    /// created are still standing — so the chain never returns to its opening fingerprint. Fourteen of the twenty
    /// recorded values are therefore distinct, against a floor of twelve in `ReplayChain.parity`.
    ///
    /// As in the standard chain, an equal fingerprint would not by itself prove a step was inert, nor a different
    /// one prove it did what it was added for. What proves each step ran is `EditSessionReplayParityTest.kt`
    /// asserting every `nativeApplyEditIntent` returned `true`, and `EditReplayWebGoldenTests` asserting the same
    /// of `ScoreEditSession.apply` — those catch a step that starts being refused, which a `nil`-planning intent
    /// (see `ScoreEditSession.structuralParityCommand` and `ScoreEditSession.rangeCommand(for:in:)`, where
    /// restating what the score already says plans to nothing) would be if a future change made one of these steps
    /// a no-op.
    static func parity(staff: StaffAddress) -> [EditReplayStep] { // swiftlint:disable:this function_body_length
        let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let measure1 = MeasureRef(measureIndex: 1)
        let measure2 = MeasureRef(measureIndex: 2)
        // Steps 6 and 8 apply the identical intent — see "Index stability" above on why one value is bound once
        // and used twice rather than spelled out again, which would let the two drift apart.
        let move = EditReplayStep.intent(.moveToVoice(
            at: VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            to: VoiceRef(staff: staff, measureIndex: 0, voiceIndex: 1),
        ))
        let tiedHead = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 0, elementIndex: 0)
        let tiedTail = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 0, elementIndex: 1)
        let secondBeat = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        let restsOfBar1 = VoiceElementRange(
            start: VoiceElementID(staff: staff, measureIndex: 1, voiceIndex: 0, elementIndex: 0),
            end: VoiceElementID(staff: staff, measureIndex: 1, voiceIndex: 0, elementIndex: 3),
        )
        // Steps 17 and 19 apply the identical intent — bound once for the reason `move` is.
        let deleteSecondBeat = EditReplayStep.intent(
            .deleteRange(over: VoiceElementRange(start: secondBeat, end: secondBeat)),
        )

        return [
            // Step 1: ask measure 1 for a system break. The fixture declares none, so this is a real flag write.
            .intent(.setLayoutBreak(at: measure1, kind: .line, enabled: true)),
            // Step 2: a double barline at the end of measure 1 — appended, since that bar carries none.
            .intent(.setBarLine(at: measure1, style: .double)),
            // Step 3: make measure 1 both open a repeat and end one played twice. Written on the canonical staff's
            // `Measure` flags, not as elements, so it neither sees nor disturbs step 2's barline.
            .intent(.setRepeatBarLines(at: measure1, startRepeat: true, endRepeatCount: 2)),
            // Step 4: group cello measures 2-3 under a `%`. Both are single-voice measure rests, which is what
            // `SetMeasureRepeat` requires; the flute's measures 2-3 are not, hence the cello.
            .intent(.setMeasureRepeat(at: measure2, staff: cello, numMeasures: 2)),
            // Step 5: dissolve that group again — `SetMeasureRepeat`'s clear path and its own wire bytes, which a
            // chain that only ever wrote a group would never encode.
            .intent(.setMeasureRepeat(at: measure2, staff: cello, numMeasures: nil)),
            // Step 6: move the flute's first quarter into a voice 1 that does not exist yet.
            move,
            // Step 7 / step 8: undo the move, then re-apply the identical intent — this chain's redo.
            .undo,
            move,
            // Step 9: clear measure 1's barline back to normal — the removal branch of `SetBarLine`.
            .intent(.setBarLine(at: measure1, style: .normal)),
            // Step 10: and clear the system break, the removal branch of `SetLayoutBreak`.
            .intent(.setLayoutBreak(at: measure1, kind: .line, enabled: false)),
            // Step 11: move the tied E4 halves of measure 2 up a semitone by naming only the chain's HEAD — the
            // whole chain follows (one sounding note), and the accidental lands on the head alone.
            .intent(.transposeRange(
                over: VoiceElementRange(start: tiedHead, end: tiedHead), semitones: 1, respellInKey: false,
            )),
            // Step 12: and back down, this time with `respellInKey` — the only step encoding that flag set. Lands
            // back on step 10's fingerprint, correctly: F down a semitone is E again, in either spelling.
            .intent(.transposeRange(
                over: VoiceElementRange(start: tiedHead, end: tiedTail), semitones: -1, respellInKey: true,
            )),
            // Step 13: a third above the D4 at beat 2 of bar 1 — F4 in C major. Beat 2 is element 2 of voice 0
            // whatever step 8 did to voice 1: `MoveToVoice` swapped element 1 for a same-length rest.
            .intent(.addIntervalToSelection(over: VoiceElementRange(start: secondBeat, end: secondBeat), steps: 3)),
            // Step 14: sharpen both notes of that chord — D♯ and F♯, letters kept.
            .intent(.setAccidentalsInRange(
                over: VoiceElementRange(start: secondBeat, end: secondBeat), accidental: .sharp,
            )),
            // Step 15: and respell them flat-wise — E♭ and G♭ at the same pitches.
            .intent(.respellRange(over: VoiceElementRange(start: secondBeat, end: secondBeat), mode: .preferFlats)),
            // Step 16: four quarter rests to halves — `[q q q q] → [h h]`, the consumed-onset rule on the wire.
            // The band is every voice of the flute, so voice 1's measure rest in that bar is shortened too.
            .intent(.setDurationInRange(over: restsOfBar1, duration: .half)),
            // Step 17: delete the chord at beat 2. Voice 0 of bar 1 is then all rests and collapses to one measure
            // rest, the same shape a click-delete leaves; voice 1 keeps its C4 and its rhythm.
            deleteSecondBeat,
            // Step 18 / step 19: undo the delete, then re-apply the identical intent — the chain's second redo.
            .undo,
            deleteSecondBeat,
        ]
    }
}
