import SheetMusicFoundation

extension Score {
    /// Returns every `ScoreItemID` (note or rest) inside the
    /// rectangular selection bounded by `anchor` and `target`.
    ///
    /// The region is `min(staff)...max(staff)` × `min(time)...max(time)`,
    /// where `time` is the element's tick position within the score
    /// (measure index primary, tick offset within measure secondary).
    /// All voices within the staff range are covered — chord notes,
    /// and rests, whose onset falls in `[tickLo, tickHi]` are
    /// included.
    ///
    /// The range is inclusive on both ends. `anchor` and `target` may
    /// be in either order. Returns `[]` if either ID does not resolve
    /// to a valid item in this score.
    public func items(
        inRangeFrom anchor: ScoreItemID,
        to target: ScoreItemID,
    ) -> [ScoreItemID] {
        guard let anchorStart = onset(of: VoiceElementID(anchor)),
              let targetStart = onset(of: VoiceElementID(target)),
              let anchorEnd = end(of: VoiceElementID(anchor)),
              let targetEnd = end(of: VoiceElementID(target))
        else { return [] }
        let anchorAddr = anchor.staff
        let targetAddr = target.staff
        let lo = min(anchorAddr, targetAddr)
        let hi = max(anchorAddr, targetAddr)
        // Lower bound = whichever endpoint STARTS earlier; upper
        // bound = whichever endpoint ENDS later. Using the END for
        // posHi is what makes the rectangle cover the full duration
        // of the longer endpoint — e.g. shift-clicking a whole note
        // in staff 2 from a single eighth in staff 1 selects every
        // eighth that overlaps the whole note's tick span, not just
        // the two endpoints.
        let posLo = min(anchorStart, targetStart)
        let posHi = max(anchorEnd, targetEnd)

        var result: [ScoreItemID] = []
        for (addr, staff) in allStaves where (lo ... hi).contains(addr) {
            let measures = staff.measures
            let measureDurations = measures.effectiveMeasureDurations()
            for mIdx in posLo.measure ... posHi.measure {
                guard measures.indices.contains(mIdx) else { continue }
                let measureDuration = measureDurations[mIdx]
                for (vIdx, voice) in measures[mIdx].voices.enumerated() {
                    var tick = 0
                    for (eIdx, el) in voice.elements.enumerated() {
                        // Same cursor `onset(of:)` walks, `.locationShift` jogs included.
                        defer { tick += el.cursorAdvance(division: division, in: measureDuration) }
                        let pos = ScoreTickPosition(measure: mIdx, tick: tick)
                        // posHi is exclusive (it's the END tick of
                        // the later endpoint, i.e. the start of
                        // whatever comes after). An element STARTING
                        // exactly at posHi sits past the range.
                        let inRange = pos >= posLo && pos < posHi
                        switch el {
                        case let .chord(chord) where !chord.notes.isEmpty:
                            if inRange {
                                for nIdx in chord.notes.indices {
                                    result.append(.note(NoteID(
                                        staff: addr,
                                        measureIndex: mIdx,
                                        voiceIndex: vIdx,
                                        elementIndex: eIdx,
                                        noteIndexInChord: nIdx,
                                    )))
                                }
                            }
                        case .chord:
                            // Empty chord — selectable as a rest.
                            if inRange {
                                result.append(.rest(RestID(
                                    staff: addr,
                                    measureIndex: mIdx,
                                    voiceIndex: vIdx,
                                    elementIndex: eIdx,
                                )))
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }
        return result
    }
}
