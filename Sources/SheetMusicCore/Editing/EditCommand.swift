import SheetMusicFoundation

/// A single, undoable mutation applied to a `Score`.
///
/// Commands are pure values: applying a command produces its inverse,
/// which when applied restores the original state. `ScoreEditor`
/// keeps the inverses on an undo stack and replays them for `undo()`.
///
/// Concrete commands should:
///   * Validate that the target path is current; throw
///     `SheetMusicError.invalidEdit` otherwise.
///   * Capture enough state in the inverse to fully reverse the
///     change (old element, old pitch, etc).
///   * Be Sendable values — no class instances, no closures.
public protocol EditCommand: Sendable {
    /// The voice-element slot the command targets. Hosts use this
    /// for post-edit affordances (auto-scroll to the affected
    /// measure, place a cursor on the new element, etc.) without
    /// having to switch over each command kind.
    var affectedLocation: VoiceElementID { get }

    /// Applies the edit to `score` in place. Returns the inverse
    /// command — applying the inverse to the post-edit `score`
    /// must restore the pre-edit state byte-for-byte.
    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand
}

extension EditCommand {
    /// Applies one command to a bare score for callers that own no editing session.
    ///
    /// A fresh per-process actor keeps minted identifiers globally unique (spec D6),
    /// but this allocator is not continuous with any `ScoreEditor`'s allocator.
    /// Never call this convenience from another command's `apply`: spec D5's replay
    /// determinism depends on recording the allocator value the command started from.
    /// A sub-command using a throwaway allocator breaks reproducibility, not uniqueness.
    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        var ids = EIDAllocator()
        return try apply(to: &score, ids: &ids)
    }

    /// Stamps the conforming command's type name as the refusal operation.
    public static func refused(_ reason: EditRefusal.Reason) -> SheetMusicError {
        .invalidEdit(EditRefusal(
            operation: String(describing: Self.self),
            reason: reason,
        ))
    }
}
