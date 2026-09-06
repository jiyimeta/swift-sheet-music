import Foundation
import Observation
import SheetMusic

/// Main-actor state for one inline lyric-entry caret.
///
/// The score stays in `NoteInputController`; every read therefore sees
/// edits and undo operations that happened after this session began.
@MainActor
@Observable
final class LyricInputSession {
    private(set) var cursor: LyricInputPlanner.Cursor?
    var text = ""

    var isActive: Bool {
        cursor != nil
    }

    func begin(
        at location: VoiceElementID,
        verse: Int,
        controller: NoteInputController,
    ) {
        cursor = LyricInputPlanner.Cursor(
            location: location, verse: verse,
        )
        refill(controller: controller)
    }

    /// Starts lyric input after closing the mutually-exclusive text
    /// session used by the same overlay.
    func begin(
        at location: VoiceElementID,
        verse: Int,
        controller: NoteInputController,
        ending textSession: TextInputSession,
    ) {
        textSession.end()
        begin(at: location, verse: verse, controller: controller)
    }

    /// Applies one planned keystroke and returns the location the host
    /// should reveal after the caret moves.
    func commit(
        _ terminator: LyricInputPlanner.Terminator,
        controller: NoteInputController,
        undoManager: UndoManager?,
    ) throws -> VoiceElementID? {
        guard let current = cursor else { return nil }
        let plan = LyricInputPlanner.plan(
            typing: text,
            terminatedBy: terminator,
            at: current,
            in: controller.score,
        )
        if let command = plan.command {
            try controller.apply(command, undoManager: undoManager)
        }
        cursor = plan.next
        guard cursor != nil else {
            end()
            return current.location
        }
        refill(controller: controller)
        return plan.next?.location
    }

    func moveVerse(
        _ direction: LyricInputPlanner.VerseDirection,
        controller: NoteInputController,
    ) {
        guard let current = cursor,
              let next = LyricInputPlanner.verseCursor(
                  direction, from: current,
              )
        else { return }
        cursor = next
        refill(controller: controller)
    }

    func movePrevious(controller: NoteInputController) {
        guard let current = cursor,
              let previous = LyricInputPlanner.previousCursor(
                  from: current, in: controller.score,
              )
        else { return }
        cursor = previous
        refill(controller: controller)
    }

    func end() {
        cursor = nil
        text = ""
    }

    private func refill(controller: NoteInputController) {
        guard let cursor else {
            text = ""
            return
        }
        text = LyricInputPlanner.lyric(
            at: cursor, in: controller.score,
        )?.text ?? ""
    }
}
