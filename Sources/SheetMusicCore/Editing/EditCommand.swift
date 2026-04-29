import Foundation

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
    /// Applies the edit to `score` in place. Returns the inverse
    /// command — applying the inverse to the post-edit `score`
    /// must restore the pre-edit state byte-for-byte.
    @discardableResult
    func apply(to score: inout Score) throws -> any EditCommand
}
