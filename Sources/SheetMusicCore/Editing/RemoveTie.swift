import SheetMusicFoundation

/// Clears the outgoing link of `start` and the incoming link of `end`, preserving their other links.
/// Removing an already-absent link succeeds and changes nothing; its inverse restores exactly the prior values.
/// A half-present link is cleared too. Missing notes are refused by `SetTie` before either note is changed.
///
/// > Note: This command is sugar over `SetTie`. It gives the operation a domain-meaningful name;
/// > callers can equally construct `SetTie` with both link values nil. See `docs/edit-commands.md`.
public struct RemoveTie: EditCommand {
    public let start: NoteID
    public let end: NoteID

    public init(start: NoteID, end: NoteID) {
        self.start = start
        self.end = end
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(start)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        try SetTie(from: start, to: end, sourceTieForward: nil, targetTieBack: nil).apply(to: &score)
    }
}
