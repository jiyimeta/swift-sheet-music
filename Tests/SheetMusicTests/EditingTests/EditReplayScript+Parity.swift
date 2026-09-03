@testable import SheetMusicCore

extension EditReplayScript {
    /// Seventy-two steps over `EditingFixtures.parityFixture()`, covering every intent the edit-command parity
    /// project appended: its structural group (30…34: `setLayoutBreak`, `setBarLine`, `setRepeatBarLines`,
    /// `setMeasureRepeat`, `moveToVoice`) in steps 1…10, its range group (35…40: `transposeRange`,
    /// `addIntervalToSelection`, `deleteRange`, `setAccidentalsInRange`, `setDurationInRange`, `respellRange`) in
    /// steps 11…19, its mark group (41…49: `setClef`, `removeClef`, `setTempo`, `setStaffText`, `setDynamic`,
    /// `setFermata`, `setBreath`, `setJumps`, `setMarkers`) in steps 20…40, its note / chord group (50…57:
    /// `setArticulation`, `setGraceNotes`, `setTremolo`, `setArpeggio`, `setGlissando`, `setDots`, `setChordLine`,
    /// `setNoteParentheses`) in steps 41…61 and its visibility group (58…61: `setElementVisible`,
    /// `setNoteVisible`, `setStemVisible`, `setBeamVisible`) in steps 64…72, prepared by two `inputNote`s
    /// (62, 63) — none of which the standard chain, which predates them, encodes at all.
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
    /// The mark group is spelled write-then-clear for every intent with a `nil` (23 / 40, 25 / 26, 28 / 34,
    /// 30 / 33, 31 / 32, 35 / 39), plus the replace path where one exists (21, 24, 29) and one undo / re-apply
    /// pair (36 / 37 / 38). `setStaffText` is written twice over — once as staff text stamped with the flute
    /// (25 / 26) and once as system text with no staff (27) — because `isSystemText` picks a different lane
    /// identity, not just a different flag byte.
    ///
    /// The note / chord group is spelled write-then-clear for every one of its eight (41 / 42, 43 / 44, 45…47,
    /// 49 / 50, 52…55, 56…58, 59 / 60), plus one undo / re-apply pair (52 / 53 / 54) and the two already-pinned
    /// intents that bracket the arpeggio: step 48 `addNoteToChord` widens the tied head to two notes so a spread is
    /// legal at all, and step 51 `removeNoteFromChord` takes that note back off. Three steps carry a payload the
    /// group has no second chance to encode: 45 writes a non-default `strokeStyle`, 46 the `.between` span (whose
    /// follower is the tail chord, named by adjacency rather than stored), and 52 a glissando with every field
    /// non-default at once. `setDots` (61) is the only member with no "off" — `dots: 0` is a value, not a clear —
    /// so it writes once, and does so last within its group for the reason given under "Index stability".
    ///
    /// The visibility group is spelled hide-then-show for every flag (64 / 65, 66 / 71, 67 / 70, 68 / 69), the
    /// beam pair naming the follower on the way down and the leader on the way up, plus one hide left standing
    /// (72) on an untimed element. Its steps — and their own index-stability and repeat notes — live on
    /// `parityVisibility()` in `EditReplayScript+Parity2.swift`, a sibling file only because this one is at its
    /// 400-line budget.
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
    /// - **Measure 2 of the FLUTE (steps 20, 21, 22, 28, 29, 30, 31, 32, 33, 34)** is where the mark group does its
    ///   index arithmetic, and every one of these steps names the index the step BEFORE it left, never the one the
    ///   fixture had. Measure 2 reads `[E4 h tied →, E4 h]` when step 20 arrives (steps 11 / 12 changed pitch, not
    ///   count, and step 12 put the reading back). Then: 20 inserts a bass clef at index 0 (the run before the head
    ///   is empty and reaches the head of the voice, so this is the bar's header clef) and the head becomes element
    ///   1; 21 names element 1 and finds that clef in its run, replacing it in place, so nothing shifts; 22 removes
    ///   the clef at element 0 and the head is element 0 again. 28 inserts `f` before the head at element 0, so the
    ///   head is element 1 and the tail element 2; 29 names element 1 and replaces that dynamic in place; 30 inserts
    ///   a fermata before the tail at element 2, so the tail is element 3; 31 puts a caesura AFTER element 3, which
    ///   appends past every index in use; 32 removes it again, naming the same element 3; 33 removes the fermata by
    ///   naming the tail (still element 3) — the removal is of the fermata its run holds, so the tail is element 2
    ///   afterwards; 34 removes the dynamic by naming the head (element 1), leaving `[E4, E4]`. Steps 35…40 address
    ///   no element of measure 2, so the final shrink is unobservable downstream.
    /// - **The system lane (steps 23, 24, 25, 26, 27, 40)** is not the element list at all: a lane write moves no
    ///   `VoiceElementID` in any voice, and the lane is addressed BY one — `SystemLaneSlot.position` turns the
    ///   anchor's onset into a `MeasurePosition`. Step 23 is the first write the fixture's EMPTY lane ever sees, so
    ///   it pads the lane to one `SystemMeasure` per measure on the way in (`RehearsalMarkLane.pad`), which is why
    ///   every later lane step can index `systemMeasures[measureIndex]` directly. The anchors: measure 1's two half
    ///   rests (elements 0 and 1 after step 16, at ticks 0 and 960) for 23 / 24 / 25 / 26 / 40, and measure 3's
    ///   untouched measure rest (element 0, which no earlier step addresses on any staff) for 27.
    /// - **Steps 35, 36, 38, 39** write `Measure.jumps` / `Measure.markers` on the canonical staff by COLUMN, like
    ///   steps 1 / 3 / 9 / 10 before them, so they move nothing; step 37 is the undo of 36 and step 38 re-applies
    ///   its identical intent, the same undo-then-reapply convention steps 6 / 7 / 8 and 17 / 18 / 19 use.
    /// - **Measure 2 of the FLUTE (steps 41…60)** needs none of the index arithmetic the mark group's steps 20…34
    ///   did, because no intent of the note / chord group inserts or removes a voice element: every payload it
    ///   writes lives INSIDE the `Chord` or the `Note`. Measure 2 reads `[E4 h tied →, E4 h]` when step 41 arrives
    ///   (step 34 removed the last of the mark group's inserted elements), and both indices stay put for the whole
    ///   block — element 0 is the head, element 1 the tail, in every one of these twenty steps. The two exceptions
    ///   are steps 48 and 51, which change the head chord's NOTE count and not the element count: 48 appends G4, so
    ///   the head reads `[E4, G4]` and `note2(0, 1)` names the G4, and 51 removes it again, leaving the head a
    ///   single note for step 52's glissando. Measure 2 is chosen over measure 0 because steps 45 / 46 (a `.between`
    ///   tremolo) and 52 (a glissando) both need a FOLLOWING sounding chord, and the tied halves are the only pair
    ///   of adjacent chords the chain still has: measure 0's voice 0 is one measure rest by step 19, and the C4
    ///   steps 6 / 8 moved sits alone in voice 1.
    /// - **Measure 1 of the FLUTE (step 61)** is the one step of this group that RETIMES, and it is deliberately
    ///   its last. Voice 0 reads `[r h, r h]` after step 16; dotting the first rest makes it a dotted half and
    ///   shortens the second to a quarter, which changes measure 1's element durations — and voice 1, whose two
    ///   half rests `SetRestDuration` does not touch, is unaffected. Every step that follows belongs to the
    ///   visibility group and addresses the CELLO, so nothing downstream can observe the retiming.
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
    /// created are still standing — so the chain never returns to its opening fingerprint.
    ///
    /// The mark group adds seven more repeats, each one a clear landing exactly on what the write it undid started
    /// from: step 22 removes the clef steps 20 / 21 wrote and lands back on step 19's value; step 26 clears the
    /// staff text step 25 wrote and lands back on step 24's; step 32 removes the breath step 31 wrote and lands
    /// back on step 30's; step 33 removes the fermata step 30 wrote and lands back on step 29's; step 34 removes
    /// the dynamic steps 28 / 29 wrote and lands back on step 27's; step 37 undoes step 36 and lands back on step
    /// 35's; step 38 re-applies step 36 and lands back on step 36's. Steps 39 and 40, which clear what steps 35 and
    /// 23 wrote, do NOT land back on an earlier value — measure 1's `Fine` marker and measure 3's system text are
    /// still standing.
    ///
    /// The note / chord group adds ten more, and every one of them is a clear landing exactly on what the write it
    /// undid started from: step 42 clears the articulation step 41 wrote and lands back on step 40's value; step 44
    /// clears the graces step 43 wrote and lands back on step 42's; step 47 removes the tremolo steps 45 / 46 wrote
    /// and lands back on step 44's; step 50 removes the arpeggio step 49 wrote and lands back on step 48's; step 51
    /// removes the note step 48 added and lands back on step 47's; step 53 undoes step 52 and lands back on step
    /// 51's; step 54 re-applies step 52 and lands back on step 52's; step 55 removes the glissando and lands back
    /// on step 51's again; step 58 clears the chord lines steps 56 / 57 wrote and lands back on step 55's; and step
    /// 60 clears the parentheses step 59 wrote and lands back on step 58's. Step 61 does not: nothing takes its dot
    /// back.
    ///
    /// The visibility group adds eleven values and four more repeats, listed on `parityVisibility()`; the chain
    /// now ends on ITS last step, the standing hide of the cello's 4/4, which no earlier step produced. Forty-six
    /// of the seventy-three recorded values are therefore distinct, against a floor of thirty-nine in
    /// `ReplayChain.parity`.
    ///
    /// As in the standard chain, an equal fingerprint would not by itself prove a step was inert, nor a different
    /// one prove it did what it was added for. What proves each step ran is `EditSessionReplayParityTest.kt`
    /// asserting every `nativeApplyEditIntent` returned `true`, and `EditReplayWebGoldenTests` asserting the same
    /// of `ScoreEditSession.apply` — those catch a step that starts being refused, which a `nil`-planning intent
    /// (see `ScoreEditSession.structuralParityCommand`, `ScoreEditSession.rangeCommand(for:in:)`,
    /// `ScoreEditSession.markCommand(for:in:)`, `ScoreEditSession.notationCommand(for:in:)` and
    /// `ScoreEditSession.visibilityCommand(for:in:)`, where restating what the score already says plans to
    /// nothing) would be if a future change made one of these steps a no-op.
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
        let measure3 = MeasureRef(measureIndex: 3)
        let firstRestOfBar1 = VoiceElementID(staff: staff, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        let secondRestOfBar1 = VoiceElementID(staff: staff, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
        let bar3Rest = VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 0, elementIndex: 0)
        func bar2(_ element: Int) -> VoiceElementID {
            VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 0, elementIndex: element)
        }
        // Steps 36 and 38 apply the identical intent — bound once for the reason `move` is.
        let fineMarker = EditReplayStep.intent(.setMarkers(
            at: measure1, markers: [Marker(kind: .fine, label: "fine", text: "Fine")],
        ))
        func note2(_ element: Int, _ noteIndex: Int) -> NoteID {
            NoteID(
                staff: staff, measureIndex: 2, voiceIndex: 0,
                elementIndex: element, noteIndexInChord: noteIndex,
            )
        }
        // Steps 52 and 54 apply the identical intent — bound once for the reason `move` is.
        let glissando = EditReplayStep.intent(.setGlissando(
            at: note2(0, 0),
            glissando: Glissando(style: .portamento, visualType: .wavy, easeIn: 25, easeOut: 75, text: "gliss."),
        ))

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
            // Step 20: a bass clef before the tied E4 head — the bar's first timed element, so the clef becomes
            // the bar's header clef at index 0 and every later index in measure 2 shifts by one.
            .intent(.setClef(before: bar2(0), clef: .bass)),
            // Step 21: an alto clef before the same head, now element 1 — the clef at 0 is in its run and is
            // replaced in place, which is the wire's second `setClef` shape.
            .intent(.setClef(before: bar2(1), clef: .alto)),
            // Step 22: and remove it — measure 2 is `[E4, E4]` again, so this lands back on step 19's fingerprint.
            .intent(.removeClef(at: bar2(0))),
            // Step 23: ♩ = 150 at the head of measure 1 — the first write into the EMPTY system lane, which pads it
            // to one entry per measure on the way in (hashing like an absent lane, so only the tempo moves the
            // fingerprint).
            .intent(.setTempo(anchor: firstRestOfBar1, marking: SetTempo.Marking(beatsPerSecond: 2.5))),
            // Step 24: ♩. = 80 at the same beat — the replace path, and the only step encoding a dotted beat.
            .intent(.setTempo(
                anchor: firstRestOfBar1, marking: SetTempo.Marking(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1),
            )),
            // Step 25: staff text at beat 3 of measure 1, stamped with the flute.
            .intent(.setStaffText(anchor: secondRestOfBar1, text: "pizz.", isSystemText: false)),
            // Step 26: and cleared — lands back on step 24's fingerprint.
            .intent(.setStaffText(anchor: secondRestOfBar1, text: nil, isSystemText: false)),
            // Step 27: system text at the head of measure 3 — `isSystemText` set, no staff.
            .intent(.setStaffText(anchor: bar3Rest, text: "rit.", isSystemText: true)),
            // Step 28: `f` before the tied head — inserted at index 0, shifting measure 2 by one again.
            .intent(.setDynamic(at: bar2(0), subtype: "f")),
            // Step 29: `pp` on the same head, now element 1 — replaced in place.
            .intent(.setDynamic(at: bar2(1), subtype: "pp")),
            // Step 30: a fermata over the tail (element 2 since step 28) — inserted before it; the tail is 3 now.
            .intent(.setFermata(at: bar2(2), subtype: "fermataAbove", timeStretch: 2)),
            // Step 31: a caesura after the tail (element 3 since step 30) — inserted after it.
            .intent(.setBreath(after: bar2(3), kind: .caesura(.normal), pause: 0.5)),
            // Step 32: and removed — lands back on step 30's fingerprint.
            .intent(.setBreath(after: bar2(3), kind: nil, pause: 0)),
            // Step 33: the fermata removed (the tail is still element 3) — lands back on step 29's.
            // `timeStretch` is 0 on a removal: the wire zeroes it when `hasFermata == 0`, so any other value here
            // would describe bytes the codec cannot produce.
            .intent(.setFermata(at: bar2(3), subtype: nil, timeStretch: 0)),
            // Step 34: the dynamic removed (the head is element 1) — measure 2 is `[E4, E4]` again, and the score
            // as a whole is exactly what step 27 left: this lands back on step 27's fingerprint.
            .intent(.setDynamic(at: bar2(1), subtype: nil)),
            // Step 35: a D.C. al Fine on the last bar.
            .intent(.setJumps(
                at: measure3, jumps: [Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")],
            )),
            // Step 36: and the Fine it jumps to, on measure 1.
            fineMarker,
            // Step 37 / step 38: undo the marker, then re-apply the identical intent — the chain's third redo.
            .undo,
            fineMarker,
            // Step 39: clear the jumps — the empty-list wire shape.
            .intent(.setJumps(at: measure3, jumps: [])),
            // Step 40: and remove the tempo — the tempo removal's wire shape. Measure 1's marker and the system
            // text in measure 3 still stand, so the chain does not return to its opening fingerprint here.
            .intent(.setTempo(anchor: firstRestOfBar1, marking: nil)),
            // Step 41: a staccato above the tied E4 head — the write shape, with an anchor.
            .intent(.setArticulation(at: bar2(0), kind: .staccato, anchor: .above, present: true)),
            // Step 42: and cleared — the wire's `present == 0`, `hasAnchor == 0` shape. Lands back on step 40's.
            .intent(.setArticulation(at: bar2(0), kind: .staccato, anchor: nil, present: false)),
            // Step 43: an acciaccatura D♯4 before the head — the nested-list write, one inner note.
            .intent(.setGraceNotes(
                at: bar2(0),
                before: [GraceChord(
                    graceType: .acciaccatura, duration: .sixteenth, notes: [Note(pitch: 63, tpc: 23)],
                )],
                after: [],
            )),
            // Step 44: both lists empty — the empty-array framing on the wire. Lands back on step 42's.
            .intent(.setGraceNotes(at: bar2(0), before: [], after: [])),
            // Step 45: two tremolo bars on the head's own stem, with a non-default stroke style.
            .intent(.setTremolo(
                at: bar2(0), tremolo: Tremolo(subtype: .r16, span: .single, strokeStyle: .traditional),
            )),
            // Step 46: the `.between` shape — the follower is the tail chord, named by adjacency, so it is accepted.
            .intent(.setTremolo(at: bar2(0), tremolo: Tremolo(subtype: .r16, span: .between))),
            // Step 47: and removed — lands back on step 44's fingerprint.
            .intent(.setTremolo(at: bar2(0), tremolo: nil)),
            // Step 48: a G4 on the head — intent 7, already pinned by the standard chain, here because an arpeggio
            // needs two notes to spread and this chain has no two-note chord left.
            .intent(.addNoteToChord(at: bar2(0), pitch: 67, tpc: 15, accidental: nil)),
            // Step 49: spread it up-straight. Subtype 4 deliberately: it is one of the two the arpeggio-direction
            // fix moved, so a regression there shows up in this chain's own bytes.
            .intent(.setArpeggio(at: bar2(0), subtype: 4)),
            // Step 50: and removed — lands back on step 48's fingerprint.
            .intent(.setArpeggio(at: bar2(0), subtype: nil)),
            // Step 51: take the G4 back off — intent 8, already pinned; the head is a single note again and this
            // lands back on step 47's fingerprint.
            .intent(.removeNoteFromChord(at: note2(0, 1))),
            // Step 52: a glissando off the head with every field non-default at once. The tail follows it, so the
            // implicit destination exists and the write is legal.
            glissando,
            // Step 53 / step 54: undo it, then re-apply the identical intent — the chain's fourth redo.
            .undo,
            glissando,
            // Step 55: and removed — lands back on step 51's fingerprint.
            .intent(.setGlissando(at: note2(0, 0), glissando: nil)),
            // Step 56: a curved fall off the TAIL, whose own chord line needs no follower.
            .intent(.setChordLine(at: bar2(1), kind: .fall, isStraight: false)),
            // Step 57: a straight doit on the same chord — the replace path, and the only step with `isStraight`
            // set.
            .intent(.setChordLine(at: bar2(1), kind: .doit, isStraight: true)),
            // Step 58: and cleared — lands back on step 55's fingerprint.
            .intent(.setChordLine(at: bar2(1), kind: nil, isStraight: false)),
            // Step 59: parentheses around the tail's notehead.
            .intent(.setNoteParentheses(at: note2(1, 0), parentheses: .both)),
            // Step 60: and removed — `.none` IS the clear, not a `nil`. Lands back on step 58's fingerprint.
            .intent(.setNoteParentheses(at: note2(1, 0), parentheses: .none)),
            // Step 61: dot the first half rest of measure 1 — the only step of this group that RETIMES, and the
            // last step of the chain for that reason. The second half rest shortens to a quarter, and nothing
            // takes that back, which is what `scriptIsNotInert` needs.
            .intent(.setDots(at: firstRestOfBar1, dots: 1)),
        ] + parityVisibility() // steps 62…72 — see `EditReplayScript+Parity2.swift`
    }
}
