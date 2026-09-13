import SheetMusicFoundation

/// The two passes that actually write spanners: re-creating the copied ones at the destination, and clearing the
/// destination's own out of the way first.
extension RangeCopySpanners {
    /// Re-creates every copied spanner at the destination, appending each command to `commands` and applying it
    /// to `scratch` as it goes.
    ///
    /// A POST-pass, run after every `ReplaceVoiceElements` has landed: the offsets are written by
    /// `Spanner.offsets(from:to:in:)` against the destination's real geometry, which needs the copy's own chords
    /// to already be there. Applying each command before planning the next matters too — inserting a line
    /// spanner shifts the element indices of everything after it in that voice, including the anchor of the next
    /// spanner to be written.
    static func recreate(
        _ source: RangeCopySource, at destinationTick: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        for stream in source.streams {
            for copied in stream.spanners {
                let geometry = RangeCopyGeometry(staff: stream.staff, in: scratch)
                guard let command = command(
                    recreating: copied, of: stream, at: destinationTick, sourceStartTick: source.startTick,
                    geometry: geometry, in: scratch,
                ) else { continue }
                _ = try command.apply(to: &scratch, ids: &ids)
                commands.append(command)
            }
        }
    }

    /// `nil` — silently — when the destination cannot hold the spanner: no chord starts at its anchor tick, or
    /// its end falls outside the score. Both are the shape `LayoutEngine`'s own resolution already drops in
    /// silence, and neither is a reason to refuse a duplicate that is otherwise writable.
    private static func command(
        recreating copied: Copied, of stream: RangeCopySource.Stream, at destinationTick: Int,
        sourceStartTick: Int, geometry: RangeCopyGeometry, in score: Score,
    ) -> (any EditCommand)? {
        let anchorTick = destinationTick + (copied.startTick - sourceStartTick)
        let endTick = destinationTick + (copied.endTick - sourceStartTick)
        guard let anchorPosition = geometry.position(atAbsolute: anchorTick),
              let anchorIndex = chordIndex(
                  at: anchorPosition, staff: stream.staff, voiceIndex: stream.voiceIndex, in: score,
              ),
              let endPosition = position(ofAbsolute: endTick, geometry: geometry)
        else { return nil }
        let anchor = VoiceElementID(
            staff: stream.staff, measureIndex: anchorPosition.measure, voiceIndex: stream.voiceIndex,
            elementIndex: anchorIndex,
        )
        guard let offsets = Spanner.offsets(from: anchor, to: endPosition, in: score) else { return nil }
        var spanner = copied.spanner
        spanner.nextMeasuresOffset = offsets.measures
        spanner.nextFractionsOffset = offsets.fractions
        switch SpannerPlacement.storage(of: spanner.kind) {
        case .chordAnchored:
            guard case var .chord(chord)? = score[anchor] else { return nil }
            chord.spanners.append(spanner)
            return AdjacentElementSlot.replacing(.chord(chord), at: anchorIndex, in: VoiceRef(anchor))
        case .voiceElement:
            return AdjacentElementSlot.inserting(
                .spanner(spanner), at: AdjacentElementSlot.insertionIndex(.before, of: anchorIndex),
                in: VoiceRef(anchor), of: score,
            )
        case .measureVolta:
            // Unreachable: a volta is never collected — `lineSpanners(for:…)` skips it and no chord carries one.
            return nil
        }
    }
}

extension RangeCopySpanners {
    /// Takes the DESTINATION's own spanners out of the span the copy is about to occupy — MuseScore's
    /// `makeGap1` → `deleteOrShortenOutSpannersFromRange` (`cmd.cpp:1505`, `edit.cpp:3638-3702`) — for the ones
    /// anchored BEFORE it.
    ///
    /// The ones anchored INSIDE the span need no command here: their anchor is material the rebuild replaces, so
    /// a chord-anchored spanner goes with its chord and `RangeCopyVoiceRebuild.place(untimed:…)` drops a
    /// `.spanner` element standing in the gap. What that per-measure rebuild cannot see is a spanner that starts
    /// before the span — possibly several bars before it — and reaches in.
    ///
    /// Every command this produces is an in-place replace, so none of them moves an element index and they may
    /// all be planned against one reading of the voice.
    static func clearDestination(
        forStream stream: RangeCopySource.Stream, at destinationTick: Int, sourceStartTick: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        guard let first = stream.elements.first else { return }
        let spanStart = destinationTick + (first.absoluteTick - sourceStartTick)
        let spanEnd = destinationTick + stream.reach(from: sourceStartTick)
        for command in destinationCommands(
            staff: stream.staff, voiceIndex: stream.voiceIndex, spanStart: spanStart, spanEnd: spanEnd,
            in: scratch,
        ) {
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
        }
    }

    private static func destinationCommands(
        staff: StaffAddress, voiceIndex: Int, spanStart: Int, spanEnd: Int, in score: Score,
    ) -> [any EditCommand] {
        let geometry = RangeCopyGeometry(staff: staff, in: score)
        let durations = score.effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        var commands: [any EditCommand] = []
        for measureIndex in geometry.measureStarts.indices
            where geometry.measureStarts[measureIndex] < spanStart
        {
            let ref = VoiceRef(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
            guard let voice = score[voice: ref], durations.indices.contains(measureIndex) else { continue }
            let measureStart = geometry.measureStarts[measureIndex]
            var tick = measureStart
            for index in voice.elements.indices {
                let element = voice.elements[index]
                defer { tick += element.cursorAdvance(division: score.division, in: durations[measureIndex]) }
                guard tick < spanStart else { continue }
                let anchor = ScoreTickPosition(measure: measureIndex, tick: tick - measureStart)
                if let command = rewrite(
                    element, at: index, anchoredAt: anchor, in: ref, reachingPast: spanStart,
                    geometry: geometry, in: score,
                ) {
                    commands.append(command)
                }
            }
        }
        return commands
    }

    /// The command that takes `element`'s spanners out of the gap starting at `spanStart`, or `nil` when none of
    /// them reaches in.
    ///
    /// Two rules, one per storage form. A SLUR touching the gap is removed outright (`edit.cpp:3686-3688`) — an
    /// arc whose far end is being written over is not an arc to anything. A hairpin-class line is SHORTENED out
    /// of it instead (`3689-3700`): it keeps its anchor and now stops where the copy begins. A volta and the
    /// system-flag spanners are skipped entirely (`:3659`).
    private static func rewrite(
        _ element: VoiceElement, at index: Int, anchoredAt anchor: ScoreTickPosition, in ref: VoiceRef,
        reachingPast spanStart: Int, geometry: RangeCopyGeometry, in score: Score,
    ) -> (any EditCommand)? {
        func reachesIn(_ spanner: Spanner) -> Bool {
            guard let end = endTick(
                of: spanner, anchoredAt: anchor, geometry: geometry, division: score.division,
            ) else { return false }
            return end > spanStart
        }
        switch element {
        case var .chord(chord):
            func doomed(_ spanner: Spanner) -> Bool {
                SpannerPlacement.storage(of: spanner.kind) == .chordAnchored && reachesIn(spanner)
            }
            guard chord.spanners.contains(where: doomed) else { return nil }
            chord.spanners.removeAll(where: doomed)
            return AdjacentElementSlot.replacing(.chord(chord), at: index, in: ref)
        case var .spanner(spanner):
            guard spanner.kind != .volta, reachesIn(spanner) else { return nil }
            let anchorID = VoiceElementID(
                staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex, elementIndex: index,
            )
            guard let boundary = position(ofAbsolute: spanStart, geometry: geometry),
                  let offsets = Spanner.offsets(from: anchorID, to: boundary, in: score)
            else { return nil }
            spanner.nextMeasuresOffset = offsets.measures
            spanner.nextFractionsOffset = offsets.fractions
            return AdjacentElementSlot.replacing(.spanner(spanner), at: index, in: ref)
        default:
            return nil
        }
    }
}
