import SheetMusicFoundation

/// Owns a mutable `Score` plus undo/redo stacks of inverse commands.
///
/// All mutations to the score must go through `apply(_:)`. Each apply
/// pushes the inverse onto the undo stack; `undo()` pops it, applies
/// it, and moves the *new* inverse onto the redo stack; `redo()` does
/// the symmetric move back.
///
/// `ScoreEditor` is a `final class` so a host app can keep a stable reference to register with `UndoManager`.
///
/// Deliberately NOT `@MainActor`. The Android JNI process pumps no main runloop, so a main-actor hop from an entry
/// point is scheduled and never resumed; the editor has to be drivable synchronously from whatever thread calls in.
/// It is not `Sendable` — hold one per isolation domain, which is what both hosts do.
public final class ScoreEditor {
    public private(set) var score: Score
    private var undoStack: [any EditCommand] = []
    private var redoStack: [any EditCommand] = []
    /// Voice-element slot most recently touched (by `apply`,
    /// `undo`, or `redo`). Hosts use this to scroll the affected
    /// measure into view, position a cursor, etc. `nil` until the
    /// first edit lands.
    public private(set) var lastAffectedLocation: VoiceElementID?

    public init(score: Score) {
        self.score = score
    }

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Applies `command`, pushes its inverse onto the undo stack,
    /// and clears the redo stack (a fresh edit invalidates redo).
    public func apply(_ command: any EditCommand) throws {
        let inverse = try command.apply(to: &score)
        undoStack.append(inverse)
        redoStack.removeAll()
        lastAffectedLocation = command.affectedLocation
    }

    /// Applies the most recent inverse off the undo stack, pushing
    /// *its* inverse onto the redo stack.
    ///
    /// The entry is only removed from `undoStack` once `apply`
    /// succeeds — peek, then pop on success — so a throwing inverse
    /// (a precondition of its own that no longer holds) leaves the
    /// stack exactly as it was rather than losing the entry while
    /// the score stays unmoved.
    public func undo() throws {
        guard let inverse = undoStack.last else {
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "undo",
                reason: .nothingToUndo,
            ))
        }
        let redo = try inverse.apply(to: &score)
        undoStack.removeLast()
        redoStack.append(redo)
        lastAffectedLocation = inverse.affectedLocation
    }

    /// Symmetric counterpart of `undo()`; see its doc comment for
    /// why the pop is deferred until after a successful `apply`.
    public func redo() throws {
        guard let command = redoStack.last else {
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "redo",
                reason: .nothingToRedo,
            ))
        }
        let inverse = try command.apply(to: &score)
        redoStack.removeLast()
        undoStack.append(inverse)
        lastAffectedLocation = command.affectedLocation
    }
}
