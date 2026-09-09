@testable import SheetMusicCore

extension EditReplayScript {
    /// The macOS score-text-entry project's chain (spec 2026-09-07): fifteen steps over
    /// `EditingFixtures.twoConsecutiveC4Chords()` — `[ts 4/4, C4 q, C4 q, r q, r q]`, elements 1 and 2 the two C4
    /// chords a hyphenated word can span — covering both intents this project appended to `EditIntentCodec`:
    /// `setLyricSyllables` (74) in steps 1…6, and `setTextVisible` (75) in steps 7…15.
    ///
    /// A THIRD chain rather than a fifth group appended to `parity(staff:)`, per `ReplayChain.parity`'s own doc
    /// comment: that chain is frozen at the edit-command parity project's own catalogue (30…73) and "a future
    /// intent family starts a third chain" — this is this project's. Intent 75 EXTENDS this chain rather than
    /// starting a fourth, because it is the same project's, and because appending steps leaves every committed
    /// `step-N.bin` of steps 1…6 byte-identical: the recording adds files and adds `goldens.txt` lines, and
    /// changes nothing that was already there.
    ///
    /// ## Index stability
    ///
    /// One hazard, and it is confined to the last two steps. A lyric write only ever assigns `Chord.lyrics` on an
    /// element that already exists, and a staff text or rehearsal mark lives in `Score.systemMeasures` — none of
    /// those changes a measure's element count, so `first` and `second` are correct through step 13. Step 14
    /// writes a CHORD SYMBOL, which `SetChordSymbol` inserts immediately before the chord it names: from there on
    /// the first chord is element 2 and the second is element 3, which is why step 15 names `firstAfterSymbol`.
    /// Nothing after step 14 addresses `first` or `second`.
    ///
    /// ## What each step covers
    ///
    /// **Lyrics (74).** A single write with no hyphenation (1); a hyphenated word spanning both chords, landing as
    /// ONE undo step — the whole reason this intent's payload is a list rather than a scalar's worth of fields (2);
    /// undone (3) and re-applied (4), the same undo-then-reapply convention `parity(staff:)`'s steps 6/7/8 use,
    /// since `EditReplayStep.redo` has no wire representation the device harness can commit; a removal that sends a
    /// non-default `syllabic` and `ticks` on a `text == nil` write, to exercise the WIRE's zeroing of both rather
    /// than trust the round-trip tests alone (5); and a melisma on a second verse — the only step naming
    /// `verse > 0` or `ticks > 0` (6).
    ///
    /// **Text visibility (75).** Every `ScoreTextID` kind, each preceded by the write that creates the text it
    /// names, since the fixture carries none: a rehearsal mark created (7) and hidden (8), undone (9) and hidden
    /// again (10) so the intent's INVERSE crosses the boundary too; a staff text created (11) and hidden (12); the
    /// verse-1 syllable step 6 left standing, hidden (13) — the kind whose flag lives inside a chord, so a
    /// fingerprint that moved the chord instead would show here; and a chord symbol created (14) and hidden (15),
    /// the one kind addressed by the chord it names rather than by its own slot.
    ///
    /// ## Fingerprints that repeat
    ///
    /// Step 3 undoes step 2 and lands back on step 1's value; step 4 re-applies step 2's identical bytes and lands
    /// back on step 2's. Step 9 undoes step 8 and lands back on step 7's; step 10 re-applies step 8's bytes and
    /// lands back on step 8's. No other step repeats — nothing later takes any of them back.
    static func lyrics(staff: StaffAddress) -> [EditReplayStep] {
        let first = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let second = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        // Step 14's insert shifts both chords one slot right; only step 15 runs after it.
        let firstAfterSymbol = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

        // Steps 8 and 10 apply the identical intent, bound once for the reason `hyphenatedWord` below is.
        let hideMark = EditReplayStep.intent(.setTextVisible(text: .rehearsalMark(measureIndex: 0), visible: false))

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
            // Step 7: a rehearsal mark on the bar — the one text kind addressed by bar rather than by anchor.
            .intent(.setRehearsalMark(measureIndex: 0, text: "A")),
            // Step 8: hide it.
            hideMark,
            // Step 9: undo, so the intent's inverse crosses the boundary as well as the intent.
            .undo,
            // Step 10: re-apply the identical bytes.
            hideMark,
            // Step 11: a staff text on the second chord's beat — a system-lane element like the mark, but matched
            // by kind, beat AND staff rather than by bar.
            .intent(.setStaffText(anchor: second, text: "pizz.", isSystemText: false)),
            // Step 12: hide it. The rehearsal mark on the same bar stays hidden and the chords stay visible.
            .intent(.setTextVisible(text: .staffText(anchor: second, style: .staffText), visible: false)),
            // Step 13: hide the verse-1 syllable step 6 wrote. Its flag lives INSIDE the chord, so a fingerprint
            // that had moved the chord's own `visible` instead would differ here.
            .intent(.setTextVisible(text: .lyric(anchor: second, verse: 1), visible: false)),
            // Step 14: a chord symbol on the first chord. This inserts a voice element — see Index stability.
            .intent(.setChordSymbol(at: first, name: "Am7", harmonyType: .standard)),
            // Step 15: hide it, named by the chord it sits on rather than by its own (shifted) slot.
            .intent(.setTextVisible(text: .harmony(anchor: firstAfterSymbol), visible: false)),
        ]
    }
}
