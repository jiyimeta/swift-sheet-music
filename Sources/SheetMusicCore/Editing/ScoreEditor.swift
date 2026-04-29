import Foundation

/// Owns a mutable `Score` plus undo/redo stacks of inverse commands.
///
/// All mutations to the score must go through `apply(_:)`. Each apply
/// pushes the inverse onto the undo stack; `undo()` pops it, applies
/// it, and moves the *new* inverse onto the redo stack; `redo()` does
/// the symmetric move back.
///
/// `ScoreEditor` is `@MainActor` and a `final class` so a host app
/// can keep a stable reference to register with `UndoManager`.
@MainActor
public final class ScoreEditor {
    public private(set) var score: Score
    private var undoStack: [any EditCommand] = []
    private var redoStack: [any EditCommand] = []

    public init(score: Score) {
        self.score = score
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Applies `command`, pushes its inverse onto the undo stack,
    /// and clears the redo stack (a fresh edit invalidates redo).
    public func apply(_ command: any EditCommand) throws {
        let inverse = try command.apply(to: &score)
        undoStack.append(inverse)
        redoStack.removeAll()
    }

    /// Pops the most recent inverse off the undo stack and applies
    /// it, pushing *its* inverse onto the redo stack.
    public func undo() throws {
        guard let inverse = undoStack.popLast() else {
            throw SheetMusicError.invalidEdit(reason: "undo: empty stack")
        }
        let redo = try inverse.apply(to: &score)
        redoStack.append(redo)
    }

    /// Symmetric counterpart of `undo()`.
    public func redo() throws {
        guard let command = redoStack.popLast() else {
            throw SheetMusicError.invalidEdit(reason: "redo: empty stack")
        }
        let inverse = try command.apply(to: &score)
        undoStack.append(inverse)
    }
}
