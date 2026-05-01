@testable import SheetMusicCore
import Testing

@Suite("CompositeEditCommand")
struct CompositeEditCommandTests {
    private static let restID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 2
    )

    @Test("apply runs each sub-command in order")
    func runsInOrder() throws {
        var score = EditingFixtures.fourQuarterRests()
        let chordA = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
        )
        let chordB = Chord(
            duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]
        )
        let composite = CompositeEditCommand(
            commands: [
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 1
                    ),
                    with: .chord(chordA)
                ),
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 2
                    ),
                    with: .chord(chordB)
                ),
            ],
            location: Self.restID
        )
        _ = try composite.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        guard case let .chord(cA) = voice.elements[1],
              case let .chord(cB) = voice.elements[2]
        else {
            Issue.record("expected chords"); return
        }
        #expect(cA.notes.first?.pitch == 60)
        #expect(cB.notes.first?.pitch == 62)
    }

    @Test("inverse undoes both sub-commands in one step")
    func inverseUndoesBoth() throws {
        var score = EditingFixtures.fourQuarterRests()
        let snapshot = score
        let chordA = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
        )
        let chordB = Chord(
            duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]
        )
        let composite = CompositeEditCommand(
            commands: [
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 1
                    ),
                    with: .chord(chordA)
                ),
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 2
                    ),
                    with: .chord(chordB)
                ),
            ],
            location: Self.restID
        )
        let inverse = try composite.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("a failing sub-command rolls back earlier successes")
    func rollsBackOnPartialFailure() throws {
        // Compose a valid swap + a target-misses-element bogus
        // command; the second should throw and the first should
        // be rolled back.
        var score = EditingFixtures.fourQuarterRests()
        let snapshot = score
        let chord = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
        )
        let bogusID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 99
        )
        let composite = CompositeEditCommand(
            commands: [
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 1
                    ),
                    with: .chord(chord)
                ),
                ReplaceVoiceElement(
                    at: bogusID,
                    with: .rest(duration: .quarter)
                ),
            ],
            location: Self.restID
        )
        #expect(throws: SheetMusicError.self) {
            _ = try composite.apply(to: &score)
        }
        #expect(score == snapshot)
    }

    @Test("apply through ScoreEditor is one undo stack entry")
    @MainActor
    func oneUndoStep() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests())
        let snapshot = editor.score
        let composite = CompositeEditCommand(
            commands: [
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 1
                    ),
                    with: .chord(Chord(
                        duration: .quarter,
                        notes: [Note(pitch: 60, tpc: 14)]
                    ))
                ),
                ReplaceVoiceElement(
                    at: VoiceElementID(
                        staffIndex: 0, measureIndex: 0,
                        voiceIndex: 0, elementIndex: 2
                    ),
                    with: .chord(Chord(
                        duration: .quarter,
                        notes: [Note(pitch: 62, tpc: 16)]
                    ))
                ),
            ],
            location: Self.restID
        )
        try editor.apply(composite)
        // Single undo brings the score back — proves the composite
        // is one stack entry, not two.
        try editor.undo()
        #expect(editor.score == snapshot)
        #expect(editor.canUndo == false)
    }
}
