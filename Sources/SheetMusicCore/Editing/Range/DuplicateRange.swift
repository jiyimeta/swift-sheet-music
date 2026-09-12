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
public struct DuplicateRange: EditCommand {
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
    /// Planning runs against a scratch score that each planned command is applied to as it is appended, because
    /// a later step has to see what an earlier one built: a rebuild for an appended bar can only be planned
    /// against a score that already has that bar. The allocator is scratch for the same reason and no identifier
    /// minted here reaches a command — the rebuilt slots carry `.fresh` / `.keep`, which is what makes replanning
    /// against the live allocator at apply time safe.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        guard let source = RangeCopySource(range: range, in: score) else {
            throw Self.refused(.targetNotFound(range.start))
        }
        var scratch = score
        var allocator = ids
        var commands: [any EditCommand] = []
        let destinationTick = source.startTick + source.lengthTicks

        try appendMeasures(
            reaching: destinationTick + source.lengthTicks, staves: source.staves,
            in: &scratch, ids: &allocator, commands: &commands,
        )
        for stream in source.streams {
            try write(
                stream, at: destinationTick, sourceStartTick: source.startTick,
                in: &scratch, ids: &allocator, commands: &commands,
            )
        }
        return commands.isEmpty ? nil : CompositeEditCommand(commands: commands, location: range.start)
    }
}

extension DuplicateRange {
    /// Appends measure columns until every staff the copy touches reaches `needed` absolute ticks.
    ///
    /// `InsertMeasure` adds a bar to every staff at once, so the loop asks the SHORTEST staff whether there is
    /// room yet rather than growing each staff on its own — appending per staff would append the column several
    /// times over. A pass that fails to lengthen the shortest staff would loop forever (a staff whose effective
    /// measure duration is zero ticks), so it is refused instead.
    private func appendMeasures(
        reaching needed: Int, staves: [StaffAddress],
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        func shortestStaffTicks(_ score: Score) -> Int {
            staves.map { RangeCopyGeometry(staff: $0, in: score).totalTicks }.min() ?? needed
        }
        var available = shortestStaffTicks(scratch)
        while available < needed {
            let command = InsertMeasure(measureIndex: MeasureStructure.measureCount(of: scratch))
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
            let grown = shortestStaffTicks(scratch)
            guard grown > available else {
                throw Self.refused(.insufficientRoom(neededTicks: needed, availableTicks: grown))
            }
            available = grown
        }
    }

    /// Places one source stream at `destinationTick` and plans the rebuild of every destination bar it reaches.
    ///
    /// `sourceStartTick` is the RANGE's start, never the stream's own first element: a voice whose first selected
    /// note starts later than the range begins must land that much later than the destination too, and measuring
    /// from the stream's own onset would pull it forward by exactly that gap.
    private func write(
        _ stream: RangeCopySource.Stream, at destinationTick: Int, sourceStartTick: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        let geometry = RangeCopyGeometry(staff: stream.staff, in: scratch)
        let durations = scratch.effectiveMeasureDurations(
            partIndex: stream.staff.partIndex, staffIndex: stream.staff.staffIndexInPart,
        )
        guard let pieces = RangeCopyPlacement.pieces(
            of: stream, at: destinationTick, sourceStartTick: sourceStartTick,
            geometry: geometry, division: scratch.division, measureDurations: durations,
        ) else {
            // The measures were appended before any stream was placed, so running out of staff here means the
            // copy needs more room than the range's own staff measured — a staff in shorter bars than the first.
            throw Self.refused(.insufficientRoom(
                neededTicks: destinationTick + stream.lengthTicks, availableTicks: geometry.totalTicks,
            ))
        }
        for piece in pieces {
            try createVoices(
                upTo: stream.voiceIndex, staff: stream.staff, measureIndex: piece.measureIndex,
                in: &scratch, ids: &ids, commands: &commands,
            )
            let command = try RangeCopyVoiceRebuild.command(
                for: piece, staff: stream.staff, voiceIndex: stream.voiceIndex, in: scratch,
            )
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
        }
    }

    /// Creates the destination voices a piece needs, in ascending order.
    ///
    /// Voices are an array and `CreateVoice` accepts only the NEXT index, so reaching voice 2 of a bar that has
    /// only voice 0 takes two commands — and the voice 1 that gets created on the way is left as the measure rest
    /// it is born with, which is what the copy means: the source had nothing to say there. A bar appended by
    /// `appendMeasures` starts with one voice, so it comes through here too.
    private func createVoices(
        upTo voiceIndex: Int, staff: StaffAddress, measureIndex: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        let location = VoiceElementID(
            staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: 0,
        )
        guard let target = scratch[staff], target.measures.indices.contains(measureIndex) else {
            throw Self.refused(.targetNotFound(location))
        }
        var existing = target.measures[measureIndex].voices.count
        while existing <= voiceIndex {
            let command = CreateVoice(staff: staff, measureIndex: measureIndex, voiceIndex: existing)
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
            existing += 1
        }
    }
}

extension RangeCopySource.Stream {
    /// How far this stream reaches from the range's start — what a placement failure has to report as needed.
    var lengthTicks: Int {
        guard let first = elements.first, let last = elements.last else { return 0 }
        return last.absoluteTick + last.lengthTicks - first.absoluteTick
    }
}
