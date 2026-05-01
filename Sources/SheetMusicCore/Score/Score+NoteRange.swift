import Foundation

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
        to target: ScoreItemID
    ) -> [ScoreItemID] {
        guard let anchorStart = tickPosition(for: anchor),
              let targetStart = tickPosition(for: target),
              let anchorEnd = endTickPosition(for: anchor),
              let targetEnd = endTickPosition(for: target)
        else { return [] }
        let staffLo = min(anchor.staffIndex, target.staffIndex)
        let staffHi = max(anchor.staffIndex, target.staffIndex)
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
        for staffIdx in staffLo ... staffHi {
            guard staves.indices.contains(staffIdx) else { continue }
            let measures = staves[staffIdx].measures
            for mIdx in posLo.measure ... posHi.measure {
                guard measures.indices.contains(mIdx) else { continue }
                for (vIdx, voice) in measures[mIdx].voices.enumerated() {
                    var tick = 0
                    for (eIdx, el) in voice.elements.enumerated() {
                        let pos = TickPosition(measure: mIdx, tick: tick)
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
                                        staffIndex: staffIdx,
                                        measureIndex: mIdx,
                                        voiceIndex: vIdx,
                                        elementIndex: eIdx,
                                        noteIndexInChord: nIdx
                                    )))
                                }
                            }
                            tick += chord.duration.ticks(division: division)
                        case let .chord(rest):
                            // Empty chord — selectable as a rest.
                            if inRange {
                                result.append(.rest(RestID(
                                    staffIndex: staffIdx,
                                    measureIndex: mIdx,
                                    voiceIndex: vIdx,
                                    elementIndex: eIdx
                                )))
                            }
                            tick += rest.duration.ticks(division: division)
                        default:
                            break
                        }
                    }
                }
            }
        }
        return result
    }

    /// Tick position one element-width past `id` — the upper bound
    /// of the time region covered by selecting `id`. Combining the
    /// two endpoints' END positions (rather than their starts) for
    /// `posHi` is what lets a long note (e.g. a whole) extend the
    /// selection rectangle across every shorter note that sits
    /// inside its tick span.
    private func endTickPosition(
        for id: ScoreItemID
    ) -> TickPosition? {
        guard let start = tickPosition(for: id),
              staves.indices.contains(id.staffIndex)
        else { return nil }
        let measures = staves[id.staffIndex].measures
        guard measures.indices.contains(id.measureIndex) else {
            return nil
        }
        let voices = measures[id.measureIndex].voices
        guard voices.indices.contains(id.voiceIndex) else {
            return nil
        }
        let elements = voices[id.voiceIndex].elements
        guard elements.indices.contains(id.elementIndex) else {
            return nil
        }
        let dur: Int
        switch elements[id.elementIndex] {
        case let .chord(c):
            dur = c.duration.ticks(division: division)
        default:
            dur = 0
        }
        return TickPosition(
            measure: start.measure, tick: start.tick + dur
        )
    }

    /// Tick position of the element referenced by `id` within its
    /// measure. Returns `nil` if the path does not resolve.
    private func tickPosition(for id: ScoreItemID) -> TickPosition? {
        guard staves.indices.contains(id.staffIndex) else { return nil }
        let measures = staves[id.staffIndex].measures
        guard measures.indices.contains(id.measureIndex) else { return nil }
        let voices = measures[id.measureIndex].voices
        guard voices.indices.contains(id.voiceIndex) else { return nil }
        let elements = voices[id.voiceIndex].elements
        guard elements.indices.contains(id.elementIndex) else { return nil }

        var tick = 0
        for i in 0 ..< id.elementIndex {
            switch elements[i] {
            case let .chord(c):
                tick += c.duration.ticks(division: division)
            default:
                break
            }
        }
        return TickPosition(measure: id.measureIndex, tick: tick)
    }
}

/// Lexicographic (measure, tick) position used to order element
/// onsets across a score.
private struct TickPosition: Comparable {
    let measure: Int
    let tick: Int

    static func < (lhs: TickPosition, rhs: TickPosition) -> Bool {
        if lhs.measure != rhs.measure { return lhs.measure < rhs.measure }
        return lhs.tick < rhs.tick
    }
}
