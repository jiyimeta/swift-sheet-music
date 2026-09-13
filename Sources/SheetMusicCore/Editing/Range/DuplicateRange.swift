import SheetMusicFoundation

/// Writes a copy of a range selection immediately after itself — MuseScore's `R` (repeat selection).
///
/// The copy starts where the selection ends and runs for the selection's own length, on every staff and in every
/// voice the selection covered. What lands there is the selection's material re-measured against the destination
/// barring: an element cut by a barline becomes a tied chain, a tuplet survives only where all of its members fit
/// one destination bar, and a rest covering a whole destination bar is written `.measure` — the same spelling
/// `DeleteRange`'s collapse produces.
///
/// The score grows when the copy runs past its last bar: the missing measure columns are appended first, which
/// lengthens EVERY staff, because a measure is a column of the score rather than a property of one staff. A
/// destination bar that lacks the voice the copy needs has it created, filled with the measure rest a new voice
/// is born with — so voice 1 stays a measure rest when a copy reaches voice 2 of a one-voice bar.
///
/// > Note: This command is sugar over `InsertMeasure` (× appended bar) + `CreateVoice` (× missing voice) +
/// > `ReplaceVoiceElements` (× destination bar-voice) bundled in a `CompositeEditCommand`, so one undo reverses
/// > the whole repeat, appended measures included. See `docs/edit-commands.md`.
public struct DuplicateRange: EditCommand, RangeCopyWriting {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: range.start)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned
    /// one refuse identically.
    ///
    /// The destination is the only thing this command decides for itself: the copy starts exactly where the
    /// selection ends. Everything after that is `RangeCopyWriting.writeCommands(for:at:in:ids:)`, shared with
    /// `PasteRange`.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        guard let source = try RangeCopySource(range: range, in: score) else {
            throw Self.refused(.targetNotFound(range.start))
        }
        let destinationTick = source.startTick + source.lengthTicks
        let commands = try writeCommands(for: source, at: destinationTick, in: score, ids: ids)
        return commands.isEmpty ? nil : CompositeEditCommand(commands: commands, location: range.start)
    }
}
