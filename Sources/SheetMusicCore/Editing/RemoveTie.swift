import SheetMusicFoundation

/// Clears the outgoing link of `start` and the incoming link of `end`, preserving their other links.
/// Requires a non-nil outgoing link matching the destination's incoming link; otherwise refuses as
/// `noTieBetween`. Missing notes are refused as `noteNotFound`. Its inverse restores exactly the prior values.
///
/// > Note: This command is sugar over `SetTie`. It gives the operation a domain-meaningful name;
/// > it validates the pair before clearing its links. See `docs/edit-commands.md`.
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
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let source = score[start] else { throw Self.refused(.noteNotFound(start)) }
        guard let target = score[end] else { throw Self.refused(.noteNotFound(end)) }
        guard source.tieForward != nil, source.tieForward == target.tieBack else {
            throw Self.refused(.noTieBetween(start: start, end: end))
        }
        return try SetTie(from: start, to: end, sourceTieForward: nil, targetTieBack: nil)
            .apply(to: &score, ids: &ids)
    }
}
