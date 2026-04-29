#if os(macOS)
import AppKit
import SheetMusicCore
import SheetMusicUI

/// Wraps `ScoreEditor` and bridges to the host's `UndoManager`.
///
/// SwiftUI hands us an `UndoManager?` from the environment; on each
/// successful `apply`, we register an undo target with the manager
/// so that `⌘Z` reaches `editor.undo()` (and the manager's redo
/// stack reaches `editor.redo()`).
@MainActor
@Observable
final class NoteInputController {
    private(set) var editor: ScoreEditor
    /// Bumped on every applied / undone / redone edit so SwiftUI
    /// `.task(id:)` observers downstream of `score` rebuild their
    /// derived state (LayoutDocument, etc).
    private(set) var version = UUID()
    /// Whether the toolbar input toggle is on. The key handler only
    /// routes letter keys when this is true.
    var isInputModeOn = false
    /// Octave used by the next letter-key input. 4 = middle-C octave.
    var inputOctave = 4

    var score: Score { editor.score }

    init(score: Score) {
        self.editor = ScoreEditor(score: score)
    }

    /// Replaces the editor's score (e.g. after loading a new file).
    /// Drops undo history.
    func reset(score: Score) {
        editor = ScoreEditor(score: score)
        version = UUID()
    }

    /// Applies a command and registers undo with `manager`. The
    /// registration is recursive: when the manager replays our undo
    /// closure, that closure also calls `registerUndo` on itself so
    /// the redo path stays linked.
    func apply(
        _ command: any EditCommand,
        undoManager manager: UndoManager?
    ) throws {
        try editor.apply(command)
        version = UUID()
        registerUndo(with: manager)
    }

    private func registerUndo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { target in
            do {
                try target.editor.undo()
                target.version = UUID()
                target.registerRedo(with: manager)
            } catch {
                NSLog("NoteInputController.undo failed: \(error)")
            }
        }
    }

    private func registerRedo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { target in
            do {
                try target.editor.redo()
                target.version = UUID()
                target.registerUndo(with: manager)
            } catch {
                NSLog("NoteInputController.redo failed: \(error)")
            }
        }
    }
}
#endif
