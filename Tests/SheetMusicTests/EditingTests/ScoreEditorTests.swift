@testable import SheetMusicCore
import Testing

@MainActor
@Suite("ScoreEditor")
struct ScoreEditorTests {
    private static let restAt1 = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )

    @Test("apply mutates the score and enables undo")
    func applyEnablesUndo() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        #expect(editor.canUndo == false)
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14,
        ))
        #expect(editor.canUndo == true)
        #expect(editor.canRedo == false)
        let veID = VoiceElementID(Self.restAt1)
        guard case .chord = editor.score[veID] else {
            Issue.record("expected chord after apply")
            return
        }
    }

    @Test("undo restores prior state and enables redo")
    func undoRestores() throws {
        let original = EditingFixtures.fourQuarterRests()
        let editor = ScoreEditor(score: original)
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14,
        ))
        try editor.undo()
        #expect(editor.score == original)
        #expect(editor.canUndo == false)
        #expect(editor.canRedo == true)
    }

    @Test("redo replays the undone command")
    func redoReplays() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14,
        ))
        let postApply = editor.score
        try editor.undo()
        try editor.redo()
        #expect(editor.score == postApply)
        #expect(editor.canUndo == true)
        #expect(editor.canRedo == false)
    }

    @Test("a fresh apply clears the redo stack")
    func freshApplyClearsRedo() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14,
        ))
        try editor.undo()
        #expect(editor.canRedo == true)
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 62, tpc: 16,
        ))
        #expect(editor.canRedo == false)
    }

    @Test("undo with empty stack throws")
    func undoEmptyThrows() {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        #expect(throws: SheetMusicError.self) {
            try editor.undo()
        }
    }

    @Test("redo with empty stack throws")
    func redoEmptyThrows() {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        #expect(throws: SheetMusicError.self) {
            try editor.redo()
        }
    }
}
