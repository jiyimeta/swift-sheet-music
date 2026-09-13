import SheetMusicFoundation

/// The write pass shared by `DuplicateRange` and `PasteRange`: given resolved copy material and the absolute tick
/// it should land at, plan every command that puts it there.
///
/// The two commands differ only in where the material and the destination tick come from — `DuplicateRange` reads
/// a range of the score being edited and lands it just after itself, `PasteRange` reads a clipboard payload and
/// lands it where the host points. Everything after that is one set of rules: the barring the destination
/// imposes, the measures that have to be appended, the voices that have to be created, the destination spanners
/// that have to be cleared and restarted, the copied spanners that have to be re-anchored. They live here so
/// neither command can drift from the other.
///
/// It is a protocol rather than a free enum so `Self.refused(_:)` keeps stamping the CONCRETE command's name on
/// every refusal raised inside the pass: a host triaging `edit.insufficientRoom` still learns whether an `R` or a
/// ⌘V produced it.
protocol RangeCopyWriting: EditCommand {}

extension RangeCopyWriting {
    /// Every command needed to write `source` at `destinationTick`, in the order they must be applied.
    ///
    /// Planning runs against a scratch score that each planned command is applied to as it is appended, because a
    /// later step has to see what an earlier one built: a rebuild for an appended bar can only be planned against
    /// a score that already has that bar. The allocator is scratch for the same reason. A planned command may
    /// still carry an identifier this scratch allocator minted — `RangeCopyVoiceRebuild`'s boundary trim keeps
    /// its head under `.keep(eid)`, and in an appended bar that `eid` came from here — but the apply runs the
    /// identical command sequence from the identical allocator value, so the live allocator mints the same
    /// identifiers in the same order and every `.keep` names an element that really exists by the time it is
    /// read.
    ///
    /// Every staff address in `source` must already be an address of `score`. For a duplicate that is free; for a
    /// paste it is `RangeCopySource.relocated(from:onto:in:)`'s job, done before the material gets here.
    ///
    /// `axis` is the staff `destinationTick` was measured on, and it is passed rather than inferred so the two
    /// can never disagree. A duplicate measures it on the range's first covered staff; a paste measures it on the
    /// staff the host named. Inferring it here as "the first staff carrying material" would be the same staff in
    /// almost every case and a different one exactly when the payload's first staff holds no chord at all — a
    /// divergence that would land that staff's material at a tick meaning something else.
    func writeCommands(
        for source: RangeCopySource, at destinationTick: Int, onAxisOf axis: StaffAddress,
        in score: Score, ids: EIDAllocator,
    ) throws -> [any EditCommand] {
        var scratch = score
        var allocator = ids
        var commands: [any EditCommand] = []
        let limit = destinationTick + reach(of: source)

        try requireOneTickAxis(across: source.staves, anchoredOn: axis, upTo: limit, in: score)
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
        return commands
    }

    /// How far past the destination's start the copy actually reaches — the largest of its streams' reaches.
    ///
    /// Usually equal to `source.lengthTicks`, but measured rather than assumed: `RangeCopySource` clamps
    /// every element's reported length to what remains of the range — except a tuplet member, exempt from
    /// the clamp to preserve its bracket's member count. Because a tuplet member can exceed the range's own
    /// reach, the actual reach of each stream must be measured instead of assumed. A stream whose own last
    /// selected element ends short of the range's end reaches that much less. Measuring per stream keeps the
    /// append pass honest about what each stream actually carries instead of asserting a length nothing in
    /// it fills.
    private func reach(of source: RangeCopySource) -> Int {
        source.streams.map { $0.reach(from: source.startTick) }.max() ?? source.lengthTicks
    }

    /// Refuses a copy whose staves do not lay their measures out identically over the span it touches.
    ///
    /// The destination tick is measured on ONE staff's axis — `anchor` — while each stream's element ticks are
    /// measured on its own staff's, and `RangeCopyPlacement` subtracts one from the other. That subtraction is an
    /// identity only while the two axes agree. They can disagree: `actualLength` is a per-measure, per-staff
    /// fact, so one staff can carry a pickup bar its neighbor does not, and a copy spanning the divergence would
    /// land that staff's material at a tick meaning something else there. Copying across staves in different
    /// barrings needs a destination resolved per staff — a design of its own — so until then it is refused rather
    /// than written wrong.
    ///
    /// `insufficientRoom` states the two lengths that disagree. It is the nearest existing reason: the
    /// destination measure this copy needs is not the size the plan measured it to be.
    private func requireOneTickAxis(
        across staves: [StaffAddress], anchoredOn anchorStaff: StaffAddress, upTo limit: Int, in score: Score,
    ) throws {
        let anchor = RangeCopyGeometry(staff: anchorStaff, in: score)
        for staff in staves where staff != anchorStaff {
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
        // Before the pieces land, so the gap each edge is measured against is still the one the rebuild will
        // clear — a destination tuplet the copy cuts widens it, and the rebuild destroys that tuplet.
        for command in RangeCopyVoiceRebuild.barlineTieSeals(
            for: pieces, staff: stream.staff, voiceIndex: stream.voiceIndex, in: scratch,
            operation: String(describing: Self.self),
        ) {
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
        }
        for piece in pieces {
            try createVoices(
                upTo: stream.voiceIndex, staff: stream.staff, measureIndex: piece.measureIndex,
                in: &scratch, ids: &ids, commands: &commands,
            )
            let command = try RangeCopyVoiceRebuild.command(
                for: piece, staff: stream.staff, voiceIndex: stream.voiceIndex, in: scratch,
                operation: String(describing: Self.self),
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
