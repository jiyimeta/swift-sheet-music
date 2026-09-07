@testable import SheetMusicCore

extension EditReplayScript {
    /// The macOS score-text-entry project's chain (spec 2026-09-07): six steps over
    /// `EditingFixtures.twoConsecutiveC4Chords()` — `[ts 4/4, C4 q, C4 q, r q, r q]`, elements 1 and 2 the two C4
    /// chords a hyphenated word can span — covering `setLyricSyllables` (74), the only intent this project
    /// appended to `EditIntentCodec`.
    ///
    /// A THIRD chain rather than a fifth group appended to `parity(staff:)`, per `ReplayChain.parity`'s own doc
    /// comment: that chain is frozen at the edit-command parity project's own catalogue (30…73) and "a future
    /// intent family starts a third chain" — this is intent 74's.
    ///
    /// ## Index stability
    ///
    /// None of this group's hazards apply. Every other chain's doc comment here is mostly about a step that
    /// inserts or removes a voice element shifting a LATER step's fixed-position target; a lyric write only ever
    /// assigns `Chord.lyrics` on an element that already exists; it never changes a measure's element count. `first`
    /// and `second` below are therefore correct for the whole script, unconditionally.
    ///
    /// ## What each step covers
    ///
    /// A single write with no hyphenation (1); a hyphenated word spanning both chords, landing as ONE undo step —
    /// the whole reason this intent's payload is a list rather than a scalar's worth of fields (2); undone (3) and
    /// re-applied (4), the same undo-then-reapply convention `parity(staff:)`'s steps 6/7/8 use, since
    /// `EditReplayStep.redo` has no wire representation the device harness can commit; a removal that sends a
    /// non-default `syllabic` and `ticks` on a `text == nil` write, to exercise the WIRE's zeroing of both rather
    /// than trust the round-trip tests alone (5); and a melisma on a second verse — the only step naming
    /// `verse > 0` or `ticks > 0` — so the chain ends on a fingerprint no earlier step produced (6).
    ///
    /// ## Fingerprints that repeat
    ///
    /// Step 3 undoes step 2 and lands back on step 1's value; step 4 re-applies step 2's identical bytes and lands
    /// back on step 2's. Steps 5 and 6 do not repeat — nothing later takes either back.
    static func lyrics(staff: StaffAddress) -> [EditReplayStep] {
        let first = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let second = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

        // Steps 2 and 4 apply the identical intent — bound once so the pair cannot drift apart, the
        // `parity(staff:)` `move` convention.
        let hyphenatedWord = EditReplayStep.intent(.setLyricSyllables(writes: [
            LyricSyllableWrite(location: first, verse: 0, text: "glo", syllabic: .begin, ticks: 0),
            LyricSyllableWrite(location: second, verse: 0, text: "ri", syllabic: .end, ticks: 0),
        ]))

        return [
            // Step 1: a single write, no hyphenation — "la" stands alone on the first chord.
            .intent(.setLyricSyllables(writes: [
                LyricSyllableWrite(location: first, verse: 0, text: "la", syllabic: .single, ticks: 0),
            ])),
            // Step 2: "glo-ri", one undo step across both chords.
            hyphenatedWord,
            // Step 3: undo it — both writes revert together.
            .undo,
            // Step 4: re-apply the identical bytes.
            hyphenatedWord,
            // Step 5: clear the first chord's syllable. `syllabic` / `ticks` are non-default here on purpose: the
            // wire zeroes them on encode (`hasText == 0`), so what the model sees is `.single` / `0` regardless.
            .intent(.setLyricSyllables(writes: [
                LyricSyllableWrite(location: first, verse: 0, text: nil, syllabic: .middle, ticks: 240),
            ])),
            // Step 6: a melisma on verse 1 of the second chord, which still carries "ri" on verse 0.
            .intent(.setLyricSyllables(writes: [
                LyricSyllableWrite(location: second, verse: 1, text: "amen", syllabic: .single, ticks: 480),
            ])),
        ]
    }
}
