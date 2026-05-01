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
        /// Bumped on every applied / undone / redone edit. Host views
        /// can `.onChange(of:)` this to trigger derived rebuilds.
        private(set) var version = UUID()
        /// Whether the toolbar input toggle is on. The key handler only
        /// routes letter keys when this is true.
        var isInputModeOn = false
        /// Octave used by the next letter-key input. 4 = middle-C octave.
        var inputOctave = 4
        /// Fires after every successful edit (apply / undo / redo).
        /// The host wires this up after construction so layout caches
        /// rebuild even when the change comes from `UndoManager`'s
        /// internal closure (which can't reach SwiftUI state on its own).
        var onScoreEdited: (@MainActor () -> Void)?

        var score: Score { editor.score }

        init(score: Score) {
            editor = ScoreEditor(score: score)
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
            onScoreEdited?()
            registerUndo(with: manager)
        }

        /// Direct undo path used by the host's keyboard handler when the
        /// system-level `UndoManager` integration isn't reachable (e.g.
        /// the score viewport is not a text-input responder, so Edit >
        /// Undo never reaches us). Mutates the editor and bumps version
        /// so the host's `onScoreEdited` callback can refresh layout.
        func undo() throws {
            try editor.undo()
            version = UUID()
            onScoreEdited?()
        }

        func redo() throws {
            try editor.redo()
            version = UUID()
            onScoreEdited?()
        }

        private func registerUndo(with manager: UndoManager?) {
            guard let manager else { return }
            manager.registerUndo(withTarget: self) { target in
                do {
                    try target.editor.undo()
                    target.version = UUID()
                    target.onScoreEdited?()
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
                    target.onScoreEdited?()
                    target.registerUndo(with: manager)
                } catch {
                    NSLog("NoteInputController.redo failed: \(error)")
                }
            }
        }
    }
#endif
