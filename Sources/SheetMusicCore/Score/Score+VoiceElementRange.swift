import SheetMusicFoundation

extension Score {
    /// Every chord and rest whose onset falls inside `range` — staves `min...max` of the two bounds, every voice,
    /// onsets in `[earlier onset, later end)` — in staff, measure, voice, element order. Exactly the region
    /// `items(inRangeFrom:to:)` resolves for a ⇧-click selection, at chord granularity instead of note granularity.
    /// `[]` when either bound does not resolve.
    public func voiceElements(in range: VoiceElementRange) -> [VoiceElementID] {
        guard let startOnset = onset(of: range.start), let endOnset = onset(of: range.end),
              let startEnd = end(of: range.start), let endEnd = end(of: range.end)
        else { return [] }
        let lo = min(range.start.staff, range.end.staff)
        let hi = max(range.start.staff, range.end.staff)
        return voiceElements(
            staves: allStaves.map(\.address).filter { (lo ... hi).contains($0) },
            from: min(startOnset, endOnset), to: max(startEnd, endEnd),
        )
    }

    /// `range`'s two bounds in chronological order — the one with the earlier onset first, ties kept as
    /// `(start, end)` — rather than the order `.staff`/`.measureIndex` addresses would suggest. `nil` when
    /// either bound's onset does not resolve in this score.
    ///
    /// `start` and `end` are only "first" and "second" by construction: a range's two bounds may fall on either
    /// staff in either order, so whichever one actually sounds first cannot be read off their addresses.
    /// Ordering by address instead of by onset is exactly the defect class this package's range-copy work found
    /// and fixed twice while it was being built — a bound picked by address rather than by time silently drops
    /// material outside the span the caller actually meant. Use this instead of comparing `.staff` or
    /// `.measureIndex` directly whenever "sorted" is supposed to mean "in time".
    public func chronologicalBounds(
        of range: VoiceElementRange,
    ) -> (earlier: VoiceElementID, later: VoiceElementID)? {
        guard let startOnset = onset(of: range.start), let endOnset = onset(of: range.end) else { return nil }
        return startOnset <= endOnset ? (range.start, range.end) : (range.end, range.start)
    }

    /// The same resolution as `voiceElements(in:)`, with the region stated outright rather than read off two
    /// slots: the staves to cover, and the half-open tick span `[posLo, posHi)` to cover them over.
    ///
    /// A `VoiceElementRange` derives its staff span from its two bounds' staves and its tick span from those same
    /// two bounds' onsets and ends, so a pair of slots cannot state an arbitrary region — covering a staff that
    /// stands at neither temporal extreme costs one of the two exact ticks. A caller that knows its extent
    /// independently (a clipboard payload: every staff it carries, over its own whole length) states it here
    /// instead of searching for two slots that happen to encode it, and `voiceElements(in:)` above becomes the
    /// special case where they do. One walk, so one resolution rule for the whole range-command family.
    ///
    /// `posLo` and `posHi` are expected to come from `onset(of:)` and `end(of:)` of real elements, as the
    /// delegation above does: `ScoreTickPosition` compares measure-first, so `(m, barTicks)` and `(m + 1, 0)`
    /// name one instant without being equal, and taking the edges from the same source as the positions being
    /// filtered keeps the comparison consistent.
    func voiceElements(
        staves: [StaffAddress], from posLo: ScoreTickPosition, to posHi: ScoreTickPosition,
    ) -> [VoiceElementID] {
        var result: [VoiceElementID] = []
        for (address, staff) in allStaves where staves.contains(address) {
            let durations = staff.measures.effectiveMeasureDurations()
            for measureIndex in posLo.measure ... posHi.measure where staff.measures.indices.contains(measureIndex) {
                for (voiceIndex, voice) in staff.measures[measureIndex].voices.enumerated() {
                    var tick = 0
                    for (elementIndex, element) in voice.elements.enumerated() {
                        // The cursor walks EVERY element, so a `.locationShift` jogs it exactly as `onset(of:)`
                        // — the two must agree or a shifted voice's chords fall outside their own range.
                        defer { tick += element.cursorAdvance(division: division, in: durations[measureIndex]) }
                        guard case .chord = element else { continue }
                        let position = ScoreTickPosition(measure: measureIndex, tick: tick)
                        if position >= posLo, position < posHi {
                            result.append(VoiceElementID(
                                staff: address, measureIndex: measureIndex,
                                voiceIndex: voiceIndex, elementIndex: elementIndex,
                            ))
                        }
                    }
                }
            }
        }
        return result
    }
}
