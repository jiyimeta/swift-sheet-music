import SheetMusicFoundation

/// Spanners across a `DuplicateRange`: which of the source's travel with the copy, and what the copy does to the
/// ones already standing where it lands.
///
/// MuseScore's copy side is all-or-nothing in both storage forms. A slur is written per ChordRest
/// (`twrite.cpp:1132-1151`), so one crossing an edge of the selection is written DANGLING and then dropped when
/// the reader cannot pair its connector — the same outcome as never writing it. A hairpin, an ottava and the
/// rest of the segment-anchored family are written only when both ends are inside the selection
/// (`twrite.cpp:3560-3571`); they are never clipped to fit.
///
/// Nothing is carried through `RangeCopyPlacement`, not even a spanner that travels. Two reasons: the stored
/// offsets are measured against the SOURCE barring and the copy may land on a different one, and a chord cut by
/// a destination barline becomes a tied chain whose every link would inherit the array. So the copy side only
/// COLLECTS — as a pair of absolute source ticks — and `recreate(_:at:in:ids:commands:)` re-anchors each one
/// against the destination after the material is there to anchor to.
enum RangeCopySpanners {
    /// One spanner the copy carries: where it starts and ends on the SOURCE staff's absolute tick axis, plus the
    /// spanner itself, whose own `nextMeasuresOffset` / `nextFractionsOffset` still describe the source and are
    /// overwritten at the destination.
    struct Copied {
        /// Absolute tick of the anchor — the chord the spanner starts on.
        let startTick: Int
        /// Absolute tick the stored offsets resolve to. For a slur that is the END CHORD'S ONSET; for a line
        /// kind it is the end element's END. `SpannerPlacement.add` draws the same distinction when it writes
        /// them, and this pair is fed straight back through `Spanner.offsets(from:to:in:)`.
        let endTick: Int
        let spanner: Spanner
    }

    /// The absolute tick `spanner`'s stored offsets resolve to, for a spanner anchored at `anchor`.
    ///
    /// `nextMeasuresOffset` counts MEASURES and `nextFractionsOffset` is measured from the anchor's own rtick, so
    /// the end is `measureStarts[anchor.measure + measures] + anchor.tick + fractionTicks`. The forward and
    /// backward carries `LayoutEngine.slurEndAnchor` performs only RE-SPELL that position across bar widths —
    /// each step subtracts a measure's width and adds the same width back through `measureStarts`, so the
    /// absolute tick never moves. This file works on the absolute axis throughout, so it needs no walk at all.
    ///
    /// `nil` when the offset names a measure the staff does not have.
    static func endTick(
        of spanner: Spanner, anchoredAt anchor: ScoreTickPosition, geometry: RangeCopyGeometry, division: Int,
    ) -> Int? {
        let measure = anchor.measure + spanner.nextMeasuresOffset
        guard geometry.measureStarts.indices.contains(measure) else { return nil }
        return geometry.measureStarts[measure] + anchor.tick
            + (spanner.nextFractionsOffset?.ticks(division: division) ?? 0)
    }

    /// Whether a spanner running from `startTick` to `endTick` lies WHOLLY inside `range`, the all-or-nothing
    /// test both storage forms take.
    ///
    /// The two forms differ by one tick, because their ends mean different things. A slur's end is a CHORD, so
    /// that chord's own onset has to be inside the range — a slur reaching the chord on the range's far edge
    /// reaches a chord the copy does not contain. A line kind's end is a TICK, so stopping exactly on the far
    /// edge is a line that fits.
    static func isEnclosed(kind: Spanner.Kind, startTick: Int, endTick: Int, in range: Range<Int>) -> Bool {
        guard range.contains(startTick), endTick >= startTick else { return false }
        return SpannerPlacement.storage(of: kind) == .chordAnchored
            ? endTick < range.upperBound
            : endTick <= range.upperBound
    }

    /// The spanners `chord` carries that the copy may take with it — and `chord.spanners` emptied either way.
    ///
    /// Emptying is unconditional for the reason the type's own note gives: a stored offset describes the source
    /// barring, so even a spanner that travels is re-anchored from scratch rather than ridden along.
    static func take(
        from chord: inout Chord, at anchor: ScoreTickPosition, absoluteTick: Int,
        geometry: RangeCopyGeometry, division: Int, range: Range<Int>,
    ) -> [Copied] {
        let kept = chord.spanners.compactMap { spanner -> Copied? in
            guard let end = endTick(of: spanner, anchoredAt: anchor, geometry: geometry, division: division),
                  isEnclosed(kind: spanner.kind, startTick: absoluteTick, endTick: end, in: range)
            else { return nil }
            return Copied(startTick: absoluteTick, endTick: end, spanner: spanner)
        }
        chord.spanners = []
        return kept
    }

    /// The `.spanner` elements standing among one stream's chords that the copy may take with it.
    ///
    /// Gathered by their own walk rather than through `RangeCopySource.isCopyable`, which still answers false for
    /// `.spanner`: an element carried through the placement would arrive with the source's offsets, and where a
    /// line's far end lands is the whole of what it says.
    ///
    /// A volta is skipped here. It is measure-granular and lives on `Score.canonicalStaff`'s measure lane
    /// (`SpannerPlacement.storage(of:)`), so it is not this staff-and-voice stream's material at all.
    static func lineSpanners(
        for ids: [VoiceElementID], staff: StaffAddress, voiceIndex: Int, geometry: RangeCopyGeometry,
        durations: [Fraction], score: Score, range: Range<Int>,
    ) -> [Copied] {
        var measureOrder: [Int] = []
        for id in ids where !measureOrder.contains(id.measureIndex) {
            measureOrder.append(id.measureIndex)
        }

        var collected: [Copied] = []
        for measureIndex in measureOrder {
            let ref = VoiceRef(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
            guard let voice = score[voice: ref], durations.indices.contains(measureIndex),
                  geometry.measureStarts.indices.contains(measureIndex)
            else { continue }
            let measureStart = geometry.measureStarts[measureIndex]
            var tick = measureStart
            for element in voice.elements.values {
                defer { tick += element.cursorAdvance(division: score.division, in: durations[measureIndex]) }
                guard case let .spanner(spanner) = element, spanner.kind != .volta else { continue }
                let anchor = ScoreTickPosition(measure: measureIndex, tick: tick - measureStart)
                guard let end = endTick(
                    of: spanner, anchoredAt: anchor, geometry: geometry, division: score.division,
                ), isEnclosed(kind: spanner.kind, startTick: tick, endTick: end, in: range) else { continue }
                collected.append(Copied(startTick: tick, endTick: end, spanner: spanner))
            }
        }
        return collected
    }
}

extension RangeCopySpanners {
    /// The `(measure, rtick)` spelling of an absolute tick, with the score's END tick resolving to the last
    /// measure's far edge rather than to nothing.
    ///
    /// `RangeCopyGeometry.position(atAbsolute:)` refuses that tick — it is the first one the staff does not have
    /// — but it is exactly where a spanner covering the last bar ends, and `Spanner.offsets(from:to:in:)`
    /// documents the same boundary on its own input (`MeasureBaseList::measureByTick` steps back onto the last
    /// measure there rather than returning nothing).
    static func position(ofAbsolute tick: Int, geometry: RangeCopyGeometry) -> ScoreTickPosition? {
        if let position = geometry.position(atAbsolute: tick) { return position }
        guard tick == geometry.totalTicks, let last = geometry.measureStarts.indices.last else { return nil }
        return ScoreTickPosition(measure: last, tick: tick - geometry.measureStarts[last])
    }

    /// The index of the chord that STARTS at `position` in one voice, or `nil` when nothing starts there.
    ///
    /// The walk is `cursorAdvance(division:in:)`, the one every other walker in this family uses, so a
    /// `.locationShift` among the elements leaves this agreeing with `Score.onset(of:)`. It stops as soon as the
    /// cursor passes the wanted tick: a spanner whose anchor tick falls INSIDE a chord rather than on its onset
    /// has nothing to attach to, and saying so is better than attaching it to the next chord along.
    static func chordIndex(
        at position: ScoreTickPosition, staff: StaffAddress, voiceIndex: Int, in score: Score,
    ) -> Int? {
        let ref = VoiceRef(staff: staff, measureIndex: position.measure, voiceIndex: voiceIndex)
        let durations = score.effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        guard let voice = score[voice: ref], durations.indices.contains(position.measure) else { return nil }
        var tick = 0
        for index in voice.elements.indices {
            let element = voice.elements[index]
            if tick == position.tick, case .chord = element { return index }
            tick += element.cursorAdvance(division: score.division, in: durations[position.measure])
            if tick > position.tick { return nil }
        }
        return nil
    }
}
