@testable import SheetMusicCore

extension EditReplayScript {
    /// The spanner group's sixteen steps — the tail of `parity(staff:)`, which appends them to its own list after
    /// the visibility group's. They live in a sibling file only because `EditReplayScript+Parity.swift` sits at its
    /// 400-line budget, and every step number below is the CHAIN's (73…88), not this array's.
    ///
    /// The group is spelled write-then-remove for the two forms that share a bar (73 / 76, 74 / 75), a running
    /// chain of seven line spanners in the CELLO's bar 2 (77…83, one removed again at 87), and one undo /
    /// re-apply pair around the volta (84 / 85 / 86). All three `<next>` spellings the writer rule distinguishes
    /// are recorded: mid-measure at 73, bar-end at 74, score-end at 84.
    ///
    /// ## Index stability
    ///
    /// A `.spanner` element inserted before a chord shifts every later index of that voice by one, and this group
    /// inserts nine of them. Two rules keep the arithmetic tractable, and both are visible in the step comments:
    /// every step names the index as the step BEFORE it left it, and the line spanners all go into ONE bar that
    /// nothing else in the chain touches, so the running count lives in one place rather than seven.
    ///
    /// - **Bar 2 of the FLUTE (steps 73…76, 88)** holds the fixture's two tied E4 halves at elements 0 and 1 —
    ///   the note / chord group left them there (step 34 removed the last of the mark group's insertions, and
    ///   nothing in the visibility group addresses the flute). `SetSlur` is chord-anchored: it rewrites the head
    ///   chord in place and moves NO index, which is why steps 73 and 76 both name element 0 and both find what
    ///   they expect. `SetHairpin` does insert, so step 74 puts a `.spanner` at element 0 and the chords become
    ///   1 and 2 for as long as it stands; step 75 takes it off again (still element 0) and step 76 then finds
    ///   the head back at element 0. Step 88 arrives with the bar at `[E4, E4]` — steps 77…87 address the cello
    ///   and the flute's bar 3 only — so it names the fixture's indices once more.
    /// - **Bar 2 of the CELLO (steps 77…83, 87)** is the fixture's bare measure rest, and the one bar-voice no
    ///   step of groups 1…6 addresses by index (steps 4 / 5 rewrite it wholesale by COLUMN and put it back). Each
    ///   line spanner is inserted immediately before that rest, so the rest is pushed one slot along per step and
    ///   the running index reads 0, 1, 2, 3, 4, 5, 6 — one place to check rather than seven. Step 87 removes the
    ///   pedal, which is still element 0, and the rest falls back to element 6.
    /// - **Bar 3 of the FLUTE (steps 84, 86)** is a measure rest carrying the group-3 jumps flag and the system
    ///   text step 27 wrote, neither of which is a voice element. `SetVolta` is measure-granular and writes on the
    ///   CANONICAL staff whatever the range names, at index 0 ahead of the bar's own signatures; step 85 undoes
    ///   it, so step 86 re-applies the identical intent against a bar that is a bare measure rest again. The volta
    ///   is left standing, and steps 87 / 88 address the cello and the flute's bar 2, so nothing observes it.
    ///
    /// ## Fingerprints that repeat
    ///
    /// Four of the sixteen land back on an earlier value: step 75 removes the hairpin step 74 wrote and lands
    /// back on step 73's; step 76 removes the slur step 73 wrote and lands back on step 72's; step 85 undoes the
    /// volta and lands back on step 83's; step 86 re-applies it and lands back on step 84's. The other twelve are
    /// new, and every one of them moves because `Chord.spanners` and the `.spanner` `VoiceElement` payload are
    /// both hashed (`ScoreFingerprintHasher.swift:289` and `:337-339`) — the fingerprint work this group's spec
    /// §2.5 required, without which steps 73 and 76 would record the value they started from. Step 88 does not
    /// repeat: nothing takes its diminuendo back, so the chain still ends on a value no earlier step produced,
    /// which is what `EditReplayDeterminismTests.scriptIsNotInert` reads.
    static func paritySpanners(staff: StaffAddress) -> [EditReplayStep] {
        let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        func bar2(_ element: Int) -> VoiceElementID {
            VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 0, elementIndex: element)
        }
        func celloBar2(_ element: Int) -> VoiceElementID {
            VoiceElementID(staff: cello, measureIndex: 2, voiceIndex: 0, elementIndex: element)
        }
        func celloRest(_ element: Int) -> VoiceElementRange {
            VoiceElementRange(start: celloBar2(element), end: celloBar2(element))
        }
        let tiedPair = VoiceElementRange(start: bar2(0), end: bar2(1))
        let lastBar = VoiceElementRange(
            start: VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 0, elementIndex: 0),
            end: VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 0, elementIndex: 0),
        )
        // Steps 84 and 86 apply the identical intent — bound once, for the reason `parity(staff:)`'s `fineMarker`
        // is: two spellings of the same bytes can drift apart, one binding cannot.
        let firstEnding = EditReplayStep.intent(.setVolta(over: lastBar, endings: [1], text: "1."))

        return [
            // Step 73: a slur across the tied pair. Chord-anchored — it rewrites the head chord in place and moves
            // NO index — and its end offsets point at the tail's ONSET, the mid-measure `<next>` spelling
            // (`<fractions>1/2</fractions>`). Visible to the goldens only because this group brought
            // `Chord.spanners` into the fingerprint.
            .intent(.setSlur(over: tiedPair)),
            // Step 74: a crescendo over the same pair. A `.spanner` element goes in BEFORE the head, so bar 2's
            // chords are elements 1 and 2 from here; the span ends at the tail's END, which is the bar line — the
            // bar-end spelling, `<measures>1</measures>` with no `<fractions>`.
            .intent(.setHairpin(over: tiedPair, subtype: .crescendo)),
            // Step 75: take the hairpin off again (it is still element 0) — lands back on step 73's fingerprint,
            // and puts the head back at element 0 for the step that follows.
            .intent(.removeSpanner(at: bar2(0), kind: .hairpin)),
            // Step 76: and the slur, off the head chord — lands back on step 72's fingerprint.
            .intent(.removeSpanner(at: bar2(0), kind: .slur)),
            // Steps 77…83: the seven remaining line spanners, all into the cello's bar 2, which no other step of
            // any group addresses by index. Each anchors on the measure rest where the previous step pushed it,
            // so the running index is 0, 1, 2, 3, 4, 5, 6 — one place to check rather than seven. A single-element
            // range is legal for a line spanner (the refusal is a slur's), and the rest is a whole bar, so each
            // records the bar-end spelling.
            .intent(.setPedal(over: celloRest(0))),
            .intent(.setOttava(over: celloRest(1), subtype: .eightVA)),
            .intent(.setTextLine(over: celloRest(2), text: "rall.")),
            .intent(.setTrill(over: celloRest(3), type: .trill)),
            .intent(.setVibrato(over: celloRest(4), type: .guitarVibrato)),
            .intent(.setPalmMute(over: celloRest(5))),
            .intent(.setLetRing(over: celloRest(6))),
            // Step 84: a first-ending volta on the last bar. Measure-granular and written on the CANONICAL staff
            // whatever the range names, at index 0 ahead of the bar's own signatures; bar 3 is the last bar, so
            // this is the score-end spelling — `<fractions>1/1</fractions>` and no `<measures>`.
            firstEnding,
            // Steps 85 / 86: undo the volta, then re-apply the identical intent — the chain's fifth redo, spelled
            // the way the others are because `EditReplayStep.redo` has no wire representation the device harness
            // can commit.
            .undo,
            firstEnding,
            // Step 87: take the pedal back off the cello (still element 0), shifting the rest back to element 6.
            .intent(.removeSpanner(at: celloBar2(0), kind: .pedal)),
            // Step 88: a diminuendo over the tied pair — bar 2 went back to `[E4, E4]` at step 76 and nothing has
            // touched it since, so the head and tail are the fixture's elements 0 and 1 again. A second hairpin
            // SUBTYPE on the wire, and a fingerprint no earlier step produced, which is what `scriptIsNotInert`
            // needs of a last step.
            .intent(.setHairpin(over: tiedPair, subtype: .dimLine)),
        ]
    }
}
