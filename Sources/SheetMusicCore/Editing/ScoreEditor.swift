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
    private var ids = EIDAllocator()

    /// A value snapshot for planning; undo and redo never roll back the live allocator.
    public var idAllocator: EIDAllocator {
        ids
    }

    private var undoStack: [any EditCommand] = []
    private var redoStack: [any EditCommand] = []
    #if DEBUG
        private var undoIdentityStack: [Set<EID>] = []
        private var redoIdentityStack: [Set<EID>] = []
    #endif
    /// Voice-element slot most recently touched (by `apply`,
    /// `undo`, or `redo`). Hosts use this to scroll the affected
    /// measure into view, position a cursor, etc. `nil` until the
    /// first edit lands.
    public private(set) var lastAffectedLocation: VoiceElementID?

    /// Identifies the adopted score with this editor's live allocator, without adding an undo step.
    /// This also covers the spec's ScoreEditSession.init chokepoint: the session constructs an editor,
    /// while hosts constructing an editor directly receive the same fully identified initial state.
    public init(score: Score) {
        self.score = score
        self.score.assignMissingIDs(using: &ids)
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
        score.assignMissingIDs(using: &ids)
        #if DEBUG
            let previousIDs = Set(EditingIdentityInvariants.identifiers(in: score))
        #endif
        let inverse = try command.apply(to: &score, ids: &ids)
        assert(!score.hasUnassignedIDs, "command dropped element identifiers")
        #if DEBUG
            // Gate 5's reach and low-level bypass are documented at check(_:ids:at:).
            EditingIdentityInvariants.check(score, ids: ids, at: .apply)
            undoIdentityStack.append(previousIDs)
            redoIdentityStack.removeAll()
        #endif
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
    ///
    /// Debug gate 7a compares the structural identifier set with the corresponding pre-apply snapshot.
    /// It covers editor/session undo only: a bare command followed by manually applying its returned
    /// inverse is invisible to this stack and is not checked. Gate 5 still checks each covered entry point.
    public func undo() throws {
        guard let inverse = undoStack.last else {
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "undo",
                reason: .nothingToUndo,
            ))
        }
        score.assignMissingIDs(using: &ids)
        #if DEBUG
            let postApplyIDs = Set(EditingIdentityInvariants.identifiers(in: score))
        #endif
        let redo = try inverse.apply(to: &score, ids: &ids)
        assert(!score.hasUnassignedIDs, "command dropped element identifiers")
        #if DEBUG
            // Gate 7a's bare-inverse blind spot is documented on undo(); count only completed checks.
            assert(EditingIdentityInvariants.restoresIDs(
                undoIdentityStack[undoIdentityStack.count - 1],
                after: Set(EditingIdentityInvariants.identifiers(in: score)),
            ), "undo changed the structural identifier set")
            EditingIdentityInvariants.check(score, ids: ids, at: .undo)
            undoIdentityStack.removeLast()
            redoIdentityStack.append(postApplyIDs)
        #endif
        undoStack.removeLast()
        redoStack.append(redo)
        lastAffectedLocation = inverse.affectedLocation
    }

    /// Symmetric counterpart of `undo()`; see its doc comment for
    /// why the pop is deferred until after a successful `apply`.
    ///
    /// Debug gate 7b catches an inverse-of-an-inverse that re-mints identifiers instead of restoring
    /// the undone edit's identifier set. Like gate 7a, it cannot see a bare inverse applied by hand.
    public func redo() throws {
        guard let command = redoStack.last else {
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "redo",
                reason: .nothingToRedo,
            ))
        }
        score.assignMissingIDs(using: &ids)
        #if DEBUG
            let previousIDs = Set(EditingIdentityInvariants.identifiers(in: score))
        #endif
        let inverse = try command.apply(to: &score, ids: &ids)
        assert(!score.hasUnassignedIDs, "command dropped element identifiers")
        #if DEBUG
            assert(EditingIdentityInvariants.restoresIDs(
                redoIdentityStack[redoIdentityStack.count - 1],
                after: Set(EditingIdentityInvariants.identifiers(in: score)),
            ), "redo changed the identifier set the undone edit produced")
            EditingIdentityInvariants.check(score, ids: ids, at: .redo)
            redoIdentityStack.removeLast()
            undoIdentityStack.append(previousIDs)
        #endif
        redoStack.removeLast()
        undoStack.append(inverse)
        lastAffectedLocation = command.affectedLocation
    }
}
