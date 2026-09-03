@testable import SheetMusicCore
import Testing

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

    /// If `undo()`/`redo()` popped the stack before calling `apply`, a throwing
    /// inverse would vanish: the entry is gone, but the score never moved, so
    /// every later undo/redo is misaligned against the score. Driving this
    /// honestly from the public command set is structurally hard — the LIFO
    /// stack only ever holds inverses that resolve, because every other
    /// public entry point (`apply`, `undo`, `redo`) keeps the stacks and the
    /// score in lockstep. So this uses a pair of test-local `EditCommand`s: one
    /// that applies cleanly but hands back an inverse that always throws.
    @Test("undo does not lose the stack entry when the inverse throws")
    func undoSurvivesThrowingInverse() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        try editor.apply(PushesThrowingInverse(location: VoiceElementID(Self.restAt1)))
        #expect(editor.canUndo == true)

        #expect(throws: SheetMusicError.self) {
            try editor.undo()
        }

        // The entry must still be there for a subsequent, real undo to reach.
        #expect(editor.canUndo == true)

        try editor.apply(InputNote(at: Self.restAt1, pitch: 60, tpc: 14))
        let postApply = editor.score
        try editor.undo()
        #expect(editor.score == EditingFixtures.fourQuarterRests())
        try editor.redo()
        #expect(editor.score == postApply)
    }

    /// If `undo()`/`redo()` popped before calling `apply`, this loss would
    /// happen for redo too, so this mirrors `undoSurvivesThrowingInverse` for
    /// the redo side. Getting a throwing entry onto the REDO stack needs one
    /// more layer than the undo case: a redo entry is whatever a successful
    /// `undo()` hands back, so the seed command's inverse (applied by
    /// `undo()`) must itself succeed and hand back `AlwaysThrows`.
    @Test("redo does not lose the stack entry when the inverse throws")
    func redoSurvivesThrowingInverse() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests(),
        )
        try editor.apply(SeedsThrowingRedo(location: VoiceElementID(Self.restAt1)))
        try editor.undo()
        #expect(editor.canRedo == true)

        #expect(throws: SheetMusicError.self) {
            try editor.redo()
        }

        // The entry must still be there for a subsequent, real redo to reach.
        #expect(editor.canRedo == true)
    }

    /// Applies cleanly and hands back `AlwaysThrows` as its inverse.
    private struct PushesThrowingInverse: EditCommand {
        let location: VoiceElementID

        var affectedLocation: VoiceElementID {
            location
        }

        func apply(to _: inout Score) throws -> any EditCommand {
            AlwaysThrows(location: location)
        }
    }

    /// Applies cleanly and hands back `PushesThrowingInverse` as its inverse,
    /// so undoing this seeds the redo stack with an entry that throws.
    private struct SeedsThrowingRedo: EditCommand {
        let location: VoiceElementID

        var affectedLocation: VoiceElementID {
            location
        }

        func apply(to _: inout Score) throws -> any EditCommand {
            PushesThrowingInverse(location: location)
        }
    }

    /// Throws unconditionally, standing in for an inverse whose precondition
    /// no longer holds by the time it is replayed.
    private struct AlwaysThrows: EditCommand {
        let location: VoiceElementID

        var affectedLocation: VoiceElementID {
            location
        }

        func apply(to _: inout Score) throws -> any EditCommand {
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "AlwaysThrows",
                reason: .targetNotFound(location),
            ))
        }
    }
}
