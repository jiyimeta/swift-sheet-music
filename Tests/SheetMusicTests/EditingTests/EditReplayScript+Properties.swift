@testable import SheetMusicCore

extension EditReplayScript {
    /// Eleven accepting steps over `EditingFixtures.twoConsecutiveC4Chords()` covering intents 76...79.
    /// The fixture has no lyrics or property overrides. Step 1 creates the lyric; step 4 seeds all three font
    /// fields that step 5 distinguishes, so clearing and leaving unchanged both act on non-default values.
    ///
    /// No step inserts or removes a voice element: the first chord remains at element 1 and its note at index 0.
    /// Step 8 moves verse 0 to the free verse 2, preserving the lyric's color and font overrides and leaving
    /// empty verse-0/1 placeholders. Every later text address names verse 2, never the vacated source.
    ///
    /// Hand-derived fingerprint spread (one-based steps, initial state S0): steps 1...5 each introduce a new
    /// state S1...S5: lyric, lyric color, note color, font seed, mixed patch. Step 6 undoes to S4; step 7 reapplies
    /// to S5. Step 8 introduces S6 by moving the lyric, and step 9 introduces S7 by setting its placement.
    /// Step 10 undoes to S6; step 11 reapplies to S7. Thus twelve observations contain eight distinct states.
    /// These changes are all fingerprinted: lyric text/verse, both colors, font face/size/style and placement.
    /// The floor is eight, derived before recording, with no margin that could hide an inert mutation.
    ///
    /// Undo/reapply follows the lyrics chain's convention: no `.redo` step, since the device harness interprets
    /// a missing `step-N.bin` as undo. Zero-based asset indices 5 and 9 are the only missing step files.
    static func properties(staff: StaffAddress) -> [EditReplayStep] {
        let first = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let note = NoteID(
            staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )
        let lyric = ScoreTextID.lyric(anchor: first, verse: 0)
        let movedLyric = ScoreTextID.lyric(anchor: first, verse: 2)
        let mixedFont = EditReplayStep.intent(.setTextFont(
            text: lyric,
            patch: .init(face: .set("Leland"), size: .clear, style: .unchanged),
        ))
        let placement = EditReplayStep.intent(.setElementPlacement(target: .text(movedLyric), placement: .below))

        return [
            // Step 1: create the carrier using the already-recorded lyric intent (74).
            .intent(.setLyricSyllables(writes: [
                LyricSyllableWrite(location: first, verse: 0, text: "la", syllabic: .single, ticks: 0),
            ])),
            // Steps 2/3: intent 76's two address families, with distinct non-default RGBA values.
            .intent(.setElementColor(target: .text(lyric), color: ScoreColor(red: 17, green: 34, blue: 51, alpha: 68))),
            .intent(.setElementColor(
                target: .note(note), color: ScoreColor(red: 85, green: 102, blue: 119, alpha: 136),
            )),
            // Step 4: seed face, size and style so step 5's clear and unchanged are distinguishable.
            .intent(.setTextFont(text: lyric, patch: .init(face: .set("Edwin"), size: .set(12), style: .set(.bold)))),
            // Steps 5/6/7: intent 78 sets face, clears size and preserves bold, then undo and reapply.
            mixedFont,
            .undo,
            mixedFont,
            // Step 8: intent 79 moves the populated lyric to a free destination, carrying its overrides.
            .intent(.setLyricVerse(text: lyric, toVerse: 2)),
            // Steps 9/10/11: intent 77 addresses the moved lyric, then undo and reapply its placement.
            placement,
            .undo,
            placement,
        ]
    }
}
