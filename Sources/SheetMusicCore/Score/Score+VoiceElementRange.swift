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
        let posLo = min(startOnset, endOnset)
        let posHi = max(startEnd, endEnd)

        var result: [VoiceElementID] = []
        for (address, staff) in allStaves where (lo ... hi).contains(address) {
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
