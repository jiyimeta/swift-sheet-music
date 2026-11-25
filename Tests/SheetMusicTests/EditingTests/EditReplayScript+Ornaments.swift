@testable import SheetMusicCore

extension EditReplayScript {
    /// Eight accepting steps over `EditingFixtures.twoConsecutiveC4Chords()` covering intent 97, `setOrnament`: a kind
    /// written, a second kind added beside it, the first taken off, a token the model does not know, and a kind
    /// composed of several glyphs written and cleared on the other chord.
    ///
    /// No step inserts or removes a voice element — an ornament lives inside its chord — so the two chords stay at
    /// elements 1 and 2.
    ///
    /// Hand-derived fingerprint spread (one-based steps, initial state S0): step 1 introduces S1 (the trill), step 2 S2
    /// (trill and turn); step 3 undoes to S1 and step 4 re-applies to S2; step 5 introduces S3 (the turn alone), step 6
    /// S4 (turn and comma), step 7 S5 (the other chord's up mordent), and step 8 clears that one, back to S4. Nine
    /// observations, six distinct states; the floor is six.
    ///
    /// Undo/reapply follows the lyrics chain's convention: no `.redo` step, since the device harness interprets a
    /// missing `step-N.bin` as undo. Zero-based asset index 2 is the only missing step file.
    static func ornaments(staff: StaffAddress) -> [EditReplayStep] {
        let first = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let second = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        let turn = EditReplayStep.intent(.setOrnament(at: first, kind: .turn, present: true))
        return [
            // Steps 1/2: two kinds on one chord; the second is added beside the first.
            .intent(.setOrnament(at: first, kind: .trill, present: true)),
            turn,
            // Steps 3/4: undo the turn, then re-apply the identical intent.
            .undo,
            turn,
            // Step 5: the trill comes off and the turn stays.
            .intent(.setOrnament(at: first, kind: .trill, present: false)),
            // Step 6: a token outside the modeled set crosses as itself.
            .intent(.setOrnament(at: first, kind: .unknown(subtype: "ornamentComma"), present: true)),
            // Steps 7/8: a composed kind on the other chord, written and cleared.
            .intent(.setOrnament(at: second, kind: .upMordent, present: true)),
            .intent(.setOrnament(at: second, kind: .upMordent, present: false)),
        ]
    }
}
