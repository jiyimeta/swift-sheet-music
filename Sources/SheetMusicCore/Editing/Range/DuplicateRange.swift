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
    /// against a score that already has that bar. The allocator is scratch for the same reason. A planned command
    /// may still carry an identifier this scratch allocator minted — `RangeCopyVoiceRebuild`'s boundary trim
    /// keeps its head under `.keep(eid)`, and in an appended bar that `eid` came from here — but the apply runs
    /// the identical command sequence from the identical allocator value, so the live allocator mints the same
    /// identifiers in the same order and every `.keep` names an element that really exists by the time it is read.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        guard let source = try RangeCopySource(range: range, in: score) else {
            throw Self.refused(.targetNotFound(range.start))
        }
        var scratch = score
        var allocator = ids
        var commands: [any EditCommand] = []
        let destinationTick = source.startTick + source.lengthTicks
        let limit = destinationTick + reach(of: source)

        try requireOneTickAxis(across: source.staves, upTo: limit, in: score)
        try appendMeasures(
            reaching: limit, staves: source.staves,
            in: &scratch, ids: &allocator, commands: &commands,
        )
        var restarts: [RangeCopySpanners.Restart] = []
        for stream in source.streams {
            // Before the material, so a destination spanner reaching into the span is already gone — and its
            // survivors already shortened — by the time a copied one is anchored there. Otherwise
            // `RangeCopySpanners`' own same-kind guard would drop the copy's spanner instead of the stale one.
            restarts += try RangeCopySpanners.clearDestination(
                forStream: stream, at: destinationTick, sourceStartTick: source.startTick,
                in: &scratch, ids: &allocator, commands: &commands,
            )
            try write(
                stream, at: destinationTick, sourceStartTick: source.startTick,
                in: &scratch, ids: &allocator, commands: &commands,
            )
        }
        // Two post-passes: the offsets of a copied spanner, and of a destination one whose start the copy
        // swallowed, are both written against the destination's real geometry — which only exists once every
        // `ReplaceVoiceElements` above has landed on the scratch score.
        try RangeCopySpanners.recreate(
            source, at: destinationTick, in: &scratch, ids: &allocator, commands: &commands,
        )
        try RangeCopySpanners.restart(restarts, in: &scratch, ids: &allocator, commands: &commands)
        return commands.isEmpty ? nil : CompositeEditCommand(commands: commands, location: range.start)
    }
}

extension DuplicateRange {
    /// How far past the destination's start the copy actually reaches — the largest of its streams' reaches.
    ///
    /// Usually equal to `source.lengthTicks`, but not asserted to be: `RangeCopySource` clamps every element's
    /// reported length to what remains of the range (an onset inside the range whose stored duration would
    /// sound past the range's end is truncated there, never copied whole), so no stream can reach further than
    /// the range itself — but a stream whose own last selected element ends short of the range's end reaches
    /// that much less. Measuring per stream rather than assuming `lengthTicks` keeps the append pass honest
    /// about what each stream actually carries instead of asserting a length nothing in it fills.
    private func reach(of source: RangeCopySource) -> Int {
        source.streams.map { $0.reach(from: source.startTick) }.max() ?? source.lengthTicks
    }

    /// Refuses a copy whose staves do not lay their measures out identically over the span it touches.
    ///
    /// The range's own ticks — `source.startTick`, and so the destination — are measured on the FIRST covered
    /// staff's axis, while each stream's element ticks are measured on its own staff's, and `RangeCopyPlacement`
    /// subtracts one from the other. That subtraction is an identity only while the two axes agree. They can
    /// disagree: `actualLength` is a per-measure, per-staff fact, so one staff can carry a pickup bar its
    /// neighbor does not, and a copy spanning the divergence would land that staff's material at a tick meaning
    /// something else there. Copying across staves in different barrings needs a destination resolved per staff
    /// — a design of its own — so until then it is refused rather than written wrong.
    ///
    /// `insufficientRoom` states the two lengths that disagree. It is the nearest existing reason: the
    /// destination measure this copy needs is not the size the plan measured it to be.
    private func requireOneTickAxis(across staves: [StaffAddress], upTo limit: Int, in score: Score) throws {
        guard let first = staves.first else { return }
        let anchor = RangeCopyGeometry(staff: first, in: score)
        for staff in staves.dropFirst() {
            let other = RangeCopyGeometry(staff: staff, in: score)
            // Only the measures the copy can reach matter; a staff free to differ past the copy still does.
            for index in anchor.measureStarts.indices where anchor.measureStarts[index] < limit {
                guard other.measureStarts.indices.contains(index),
                      other.measureStarts[index] == anchor.measureStarts[index],
                      other.measureLength(index) == anchor.measureLength(index)
                else {
                    throw Self.refused(.insufficientRoom(
                        neededTicks: anchor.measureLength(index), availableTicks: other.measureLength(index),
                    ))
                }
            }
        }
    }

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
        guard let pieces = RangeCopyPlacement.pieces(
            of: stream, at: destinationTick, sourceStartTick: sourceStartTick,
            geometry: geometry, division: scratch.division,
        ) else {
            // The measures were appended before any stream was placed, so running out of staff here means the
            // copy needs more room than the range's own staff measured — a staff in shorter bars than the first.
            throw Self.refused(.insufficientRoom(
                neededTicks: destinationTick + stream.reach(from: sourceStartTick),
                availableTicks: geometry.totalTicks,
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
    /// How far this stream reaches past `sourceStartTick`: the furthest END any of its elements has, not its last
    /// onset, and measured from the RANGE's start rather than from the stream's own first element — a stream
    /// whose first selected element starts later than the range lands that much later than the destination, so
    /// its reach includes the gap.
    ///
    /// The maximum rather than the last entry, because the last entry need not be the furthest: a stream can end
    /// on a non-timed element, whose `lengthTicks` is zero, sitting at the same tick a chord before it already
    /// sounds through.
    func reach(from sourceStartTick: Int) -> Int {
        elements.map { $0.absoluteTick + $0.lengthTicks - sourceStartTick }.max() ?? 0
    }
}
