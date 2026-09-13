import SheetMusicFoundation

/// The write side: re-creating the copied spanners at the destination, and restarting a destination spanner
/// whose start the copy swallowed.
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
                guard let command = writeCommand(
                    copied.spanner, staff: stream.staff, voiceIndex: stream.voiceIndex,
                    startTick: destinationTick + (copied.startTick - source.startTick),
                    endTick: destinationTick + (copied.endTick - source.startTick),
                    geometry: geometry, in: scratch,
                ) else { continue }
                _ = try command.apply(to: &scratch, ids: &ids)
                commands.append(command)
            }
        }
    }

    /// Writes the spanners whose start `clearDestination(forStream:…)` found the copy had swallowed, at the far
    /// edge of the span it took. Runs after `recreate(_:at:…)` for the same reason that one runs last: the
    /// material it anchors to has to exist first.
    static func restart(
        _ requests: [Restart],
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        for request in requests {
            let geometry = RangeCopyGeometry(staff: request.staff, in: scratch)
            guard let command = writeCommand(
                request.spanner, staff: request.staff, voiceIndex: request.voiceIndex,
                startTick: request.startTick, endTick: request.endTick, geometry: geometry, in: scratch,
            ) else { continue }
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
        }
    }

    /// The command that anchors `spanner` on whatever starts at `startTick` and ends it at `endTick`, both
    /// absolute on `staff`'s axis.
    ///
    /// `nil` — silently — when the destination cannot hold it: no chord starts at the anchor tick, the end falls
    /// outside the score, or a spanner of the same kind already starts there. The first two are the shape
    /// `LayoutEngine`'s own resolution already drops in silence, and neither is a reason to refuse a duplicate
    /// that is otherwise writable. The third is `SpannerPlacement.refuseDuplicate`'s rule, enforced here rather
    /// than borrowed: these commands are built straight out of `AdjacentElementSlot`, so nothing on this path
    /// would otherwise notice, and a survivor of the same kind would quietly be joined by a second spanner.
    private static func writeCommand(
        _ spanner: Spanner, staff: StaffAddress, voiceIndex: Int, startTick: Int, endTick: Int,
        geometry: RangeCopyGeometry, in score: Score,
    ) -> (any EditCommand)? {
        guard let anchorPosition = geometry.position(atAbsolute: startTick),
              let anchorIndex = chordIndex(
                  at: anchorPosition, staff: staff, voiceIndex: voiceIndex, in: score,
              ),
              let endPosition = position(ofAbsolute: endTick, geometry: geometry)
        else { return nil }
        let anchor = VoiceElementID(
            staff: staff, measureIndex: anchorPosition.measure, voiceIndex: voiceIndex,
            elementIndex: anchorIndex,
        )
        guard let offsets = Spanner.offsets(from: anchor, to: endPosition, in: score) else { return nil }
        var written = spanner
        written.nextMeasuresOffset = offsets.measures
        written.nextFractionsOffset = offsets.fractions
        switch SpannerPlacement.storage(of: written.kind) {
        case .chordAnchored:
            guard case var .chord(chord)? = score[anchor],
                  !chord.spanners.contains(where: { $0.kind == written.kind })
            else { return nil }
            chord.spanners.append(written)
            return AdjacentElementSlot.replacing(.chord(chord), at: anchorIndex, in: VoiceRef(anchor))
        case .voiceElement:
            guard AdjacentElementSlot.find(.before, of: anchor, in: score, where: {
                if case let .spanner(existing) = $0 { existing.kind == written.kind } else { false }
            }) == nil else { return nil }
            return AdjacentElementSlot.inserting(
                .spanner(written), at: AdjacentElementSlot.insertionIndex(.before, of: anchorIndex),
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
    /// `makeGap1` → `deleteOrShortenOutSpannersFromRange` (`cmd.cpp:1505`, `edit.cpp:3638-3702`).
    ///
    /// Three of that pass's four outcomes are decided here, because the fourth is the only one a per-measure
    /// rebuild can see for itself. A spanner lying wholly inside the gap is dropped by
    /// `RangeCopyVoiceRebuild.place(untimed:…)` along with the material it was anchored to. What that walk
    /// cannot see is a spanner that starts BEFORE the span — possibly several bars before it — so the removal
    /// of a slur reaching in and the shortening of a hairpin-class line reaching in are done here, from the
    /// score's own absolute axis. The returned `Restart`s are the third outcome: a hairpin-class line anchored
    /// INSIDE the span that reaches past it, to be written again at the span's far edge once the copy has
    /// landed.
    ///
    /// Every command this produces is an in-place replace, so none of them moves an element index and they may
    /// all be planned against one reading of the voice.
    static func clearDestination(
        forStream stream: RangeCopySource.Stream, at destinationTick: Int, sourceStartTick: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws -> [Restart] {
        guard let first = stream.elements.first else { return [] }
        let span = (destinationTick + (first.absoluteTick - sourceStartTick))
            ..< (destinationTick + stream.reach(from: sourceStartTick))
        let found = scan(staff: stream.staff, voiceIndex: stream.voiceIndex, span: span, in: scratch)
        for command in found.commands {
            _ = try command.apply(to: &scratch, ids: &ids)
            commands.append(command)
        }
        return found.restarts
    }

    private static func scan(
        staff: StaffAddress, voiceIndex: Int, span: Range<Int>, in score: Score,
    ) -> (commands: [any EditCommand], restarts: [Restart]) {
        let geometry = RangeCopyGeometry(staff: staff, in: score)
        let durations = score.effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        var commands: [any EditCommand] = []
        var restarts: [Restart] = []
        for measureIndex in geometry.measureStarts.indices
            where geometry.measureStarts[measureIndex] < span.upperBound
        {
            let ref = VoiceRef(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
            guard let voice = score[voice: ref], durations.indices.contains(measureIndex) else { continue }
            let measureStart = geometry.measureStarts[measureIndex]
            var tick = measureStart
            for index in voice.elements.indices {
                let element = voice.elements[index]
                defer { tick += element.cursorAdvance(division: score.division, in: durations[measureIndex]) }
                guard tick < span.upperBound else { continue }
                let anchor = ScoreTickPosition(measure: measureIndex, tick: tick - measureStart)
                if tick < span.lowerBound {
                    if let command = rewrite(
                        element, at: index, anchoredAt: anchor, in: ref, span: span,
                        geometry: geometry, in: score,
                    ) {
                        commands.append(command)
                    }
                } else if let request = restartRequest(
                    element, anchoredAt: anchor, staff: staff, voiceIndex: voiceIndex, span: span,
                    geometry: geometry, division: score.division,
                ) {
                    restarts.append(request)
                }
            }
        }
        return (commands, restarts)
    }

    /// The command that takes `element`'s spanners out of `span`, for an element anchored BEFORE it, or `nil`
    /// when none of them reaches in.
    ///
    /// Two rules, one per storage form, and both are bounded at BOTH ends — a spanner that merely arches over
    /// the whole gap has neither endpoint inside it and MuseScore leaves it entirely alone. A SLUR whose end
    /// chord falls in `[t1, t2)` is removed outright (`edit.cpp:3686-3688`); the closed lower bound is what
    /// makes an arc ending exactly ON the gap's first tick go too, since that chord is the first thing the copy
    /// overwrites. A hairpin-class line whose end falls in `(t1, t2]` is SHORTENED instead (`3689-3700`): it
    /// keeps its anchor and now stops where the copy begins. Ending exactly on `t1` is already that, so the
    /// lower bound is open there. Every other kind — pedal, text line, palm mute, let ring, glissando, volta —
    /// is outside the pass entirely; see `isShortenedOutOfGaps(_:)`.
    private static func rewrite(
        _ element: VoiceElement, at index: Int, anchoredAt anchor: ScoreTickPosition, in ref: VoiceRef,
        span: Range<Int>, geometry: RangeCopyGeometry, in score: Score,
    ) -> (any EditCommand)? {
        func end(of spanner: Spanner) -> Int? {
            endTick(of: spanner, anchoredAt: anchor, geometry: geometry, division: score.division)
        }
        switch element {
        case var .chord(chord):
            func doomed(_ spanner: Spanner) -> Bool {
                guard SpannerPlacement.storage(of: spanner.kind) == .chordAnchored,
                      let tick = end(of: spanner) else { return false }
                return tick >= span.lowerBound && tick < span.upperBound
            }
            guard chord.spanners.contains(where: doomed) else { return nil }
            chord.spanners.removeAll(where: doomed)
            return AdjacentElementSlot.replacing(.chord(chord), at: index, in: ref)
        case var .spanner(spanner):
            guard isShortenedOutOfGaps(spanner.kind), let tick = end(of: spanner),
                  tick > span.lowerBound, tick <= span.upperBound
            else { return nil }
            let anchorID = VoiceElementID(
                staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex, elementIndex: index,
            )
            guard let boundary = position(ofAbsolute: span.lowerBound, geometry: geometry),
                  let offsets = Spanner.offsets(from: anchorID, to: boundary, in: score)
            else { return nil }
            spanner.nextMeasuresOffset = offsets.measures
            spanner.nextFractionsOffset = offsets.fractions
            return AdjacentElementSlot.replacing(.spanner(spanner), at: index, in: ref)
        default:
            return nil
        }
    }

    /// The request to write `element` again at `span.upperBound`, for a hairpin-class line anchored INSIDE the
    /// span that reaches past it — MuseScore's `moveStart` (`edit.cpp:3689-3700`). `nil` for anything else,
    /// including a line of the same class that ends inside the span: that one lies wholly in the gap, and the
    /// rebuild removes it with everything else there.
    private static func restartRequest(
        _ element: VoiceElement, anchoredAt anchor: ScoreTickPosition, staff: StaffAddress, voiceIndex: Int,
        span: Range<Int>, geometry: RangeCopyGeometry, division: Int,
    ) -> Restart? {
        guard case let .spanner(spanner) = element, isShortenedOutOfGaps(spanner.kind),
              let tick = endTick(of: spanner, anchoredAt: anchor, geometry: geometry, division: division),
              tick > span.upperBound
        else { return nil }
        return Restart(
            staff: staff, voiceIndex: voiceIndex, startTick: span.upperBound, endTick: tick, spanner: spanner,
        )
    }
}
