@testable import SheetMusicCore

extension EditReplayScript {
    /// The visibility group's eleven steps — the tail of `parity(staff:)`, which appends them to its own list.
    /// They live in a sibling file only because `EditReplayScript+Parity.swift` sits at its 400-line budget, and
    /// every step number below is the CHAIN's (62…72), not this array's.
    ///
    /// The parity fixture holds no beamable chord anywhere — quarters, halves and measure rests only
    /// (`EditingFixtures.parityFixture()`) — and it is frozen: its `fixture.mscx` is committed and drift-checked.
    /// So the group prepares its own beam pair out of two already-pinned intents (steps 62, 63) on the CELLO's bar
    /// 1, the one bar-voice no step of groups 1…4 addresses. `VisibilityPlanningTests.beamedSession()` pins the
    /// resulting shape — `[G2 e, A2 e, r q, r h]`, elements 0 and 1 one beam group led by element 0 — before a
    /// single byte is recorded here, so the chain's assumption about that shape is a test rather than a hope.
    ///
    /// The group proper is spelled hide-then-show for every flag (64 / 65, 66 / 71, 67 / 70, 68 / 69), the beam
    /// pair naming the FOLLOWER on the way down and the LEADER on the way up — step 68 is the one step that
    /// proves the planner's re-target (row 61) on the device, since the bytes carry element 1 and both images
    /// must land the flag on element 0 — plus one hide left standing (72) on an untimed element.
    ///
    /// ## Index stability
    ///
    /// - **Bar 1 of the CELLO (steps 62…71)** is a single measure rest until step 62: the armed eighth re-times
    ///   that rest and fills the remainder beat-aligned (`SetRestDuration`), so one element becomes four. Step 63
    ///   writes into the eighth rest step 62 left behind (element 1) and changes no count. Every later step names
    ///   element 0 or element 1, and nothing after step 63 inserts or removes a voice element — all four
    ///   visibility flags live INSIDE the `Chord` or the `Note`, exactly as the note / chord group's do.
    /// - **Bar 0 of the CELLO (step 72)** is the fixture's 4/4 at element 0, which no earlier step of the chain
    ///   addresses on any staff.
    ///
    /// ## Fingerprints that repeat
    ///
    /// Four of the eleven land back on an earlier value, each the show that takes back the hide before it: step 65
    /// shows the chord step 64 hid and lands back on step 63's value; step 69 shows the beam step 68 hid and lands
    /// back on step 67's; step 70 shows the stem step 67 hid and lands back on step 66's; step 71 shows the
    /// notehead step 66 hid and lands back on step 63's again. Step 72 does not — nothing takes the hidden 4/4
    /// back, so the chain still ends on a value it has never held, which is what
    /// `EditReplayDeterminismTests.scriptIsNotInert` reads.
    ///
    /// Every step here moves the fingerprint, and none of them needed fingerprint work to do it (spec §2.5): a
    /// chord's `visible` is hashed by occupants (`ScoreFingerprintHasher.swift:289` via `combineOccupied`, tag
    /// 29), `Note.visible` unconditionally (`:154`), `Chord.stemVisible` / `Chord.beamVisible` unconditionally
    /// (`:287-288`) and `TimeSignature.visible` unconditionally (`:326`) — all of it already covered before this
    /// group, which is why group 5 adds no occupant tag.
    static func parityVisibility() -> [EditReplayStep] {
        let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let celloBar1Rest = RestID(staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        let celloBar1SecondRest = RestID(staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
        func celloBar1(_ element: Int) -> VoiceElementID {
            VoiceElementID(staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: element)
        }
        let celloLeadHead = NoteID(
            staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        )
        let celloMeter = VoiceElementID(staff: cello, measureIndex: 0, voiceIndex: 0, elementIndex: 0)

        return [
            // Step 62: an eighth G2 into the cello's bar 1 — the one bar-voice no earlier step addresses. The
            // armed eighth re-times the measure rest and fills the rest of the bar beat-aligned: `[G2 e, r e,
            // r q, r h]`. Groups 1…4 left this bar alone; the visibility group needs a beam, and the fixture
            // has none.
            .intent(.inputNote(at: celloBar1Rest, pitch: 43, tpc: 15, duration: .eighth)),
            // Step 63: an A2 into the eighth rest that follows (element 1) — the bar now opens with two beamed
            // eighths, element 0 leading the group (`BeamGrouping`; pinned by `VisibilityPlanningTests`).
            .intent(.inputNote(at: celloBar1SecondRest, pitch: 45, tpc: 17, duration: nil)),
            // Step 64: hide the A2 chord whole — `Chord.visible`, the chord case of `setElementVisible`.
            .intent(.setElementVisible(at: celloBar1(1), visible: false)),
            // Step 65: and show it — lands back on step 63's fingerprint.
            .intent(.setElementVisible(at: celloBar1(1), visible: true)),
            // Step 66: hide the G2's notehead alone; its stem and the beam stay (no cascade).
            .intent(.setNoteVisible(at: celloLeadHead, visible: false)),
            // Step 67: hide the G2's stem.
            .intent(.setStemVisible(at: celloBar1(0), visible: false)),
            // Step 68: hide the beam, NAMING THE FOLLOWER (element 1). The bytes carry element 1; both images
            // re-target to the group's leader, element 0, which is the only place the flag is read from.
            .intent(.setBeamVisible(at: celloBar1(1), visible: false)),
            // Step 69: show the beam, naming the leader this time — lands back on step 67's fingerprint.
            .intent(.setBeamVisible(at: celloBar1(0), visible: true)),
            // Step 70: show the stem — lands back on step 66's.
            .intent(.setStemVisible(at: celloBar1(0), visible: true)),
            // Step 71: show the notehead — lands back on step 63's.
            .intent(.setNoteVisible(at: celloLeadHead, visible: true)),
            // Step 72: hide the cello's opening 4/4 — the untimed case of `setElementVisible`, left standing so
            // the chain ends on a fingerprint no earlier step produced, as `scriptIsNotInert` needs.
            .intent(.setElementVisible(at: celloMeter, visible: false)),
        ]
    }
}
