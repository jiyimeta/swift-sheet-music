import SheetMusicFoundation

/// Builds the ⌘C payload for a range selection: a small, self-contained `Score` holding exactly the copied
/// material. `MSCXEncoder.encode(_:)` and `MSCXParser.parse(_:)` already round-trip a `Score` in memory, so the
/// payload needs no format of its own — this type only carves the source score down to what the range covers.
///
/// The resolution rule is the same one every other range command uses: `Score.voiceElements(in:)` for the
/// covered slots, and `onset(of:)`/`end(of:)` on both bounds (taking the earlier onset and the later end) for
/// the tick span, since the two bounds may be given in either order and may name different staves.
///
/// This is deliberately much smaller than `RangeCopySource`, which builds the material `DuplicateRange` inserts
/// back into the SAME score: there is no tuplet-boundary refusal, no spanner re-anchoring, no outer-tie
/// clearing. A payload is landed by the paste engine those types already serve, so the shaping this type does
/// not do here is done once, downstream, for both a duplicate and a paste.
enum RangeCopyPayload {
    /// The copied range as a self-contained score: the covered staves, the covered measures, each voice
    /// trimmed to the range's tick span. `nil` when the range resolves to nothing.
    static func score(for range: VoiceElementRange, in score: Score) -> Score? {
        guard !score.voiceElements(in: range).isEmpty,
              let startOnset = score.onset(of: range.start), let endOnset = score.onset(of: range.end),
              let startEnd = score.end(of: range.start), let endEnd = score.end(of: range.end)
        else { return nil }

        let low = min(startOnset, endOnset)
        let high = max(startEnd, endEnd)
        guard low < high else { return nil }
        let measureRange = low.measure ... high.measure

        let staffLow = min(range.start.staff, range.end.staff)
        let staffHigh = max(range.start.staff, range.end.staff)

        var parts: [Part] = []
        for partIndex in score.parts.indices {
            let part = score.parts[partIndex]
            var staves: [Staff] = []
            for staffIndex in part.staves.indices {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                guard (staffLow ... staffHigh).contains(address),
                      let copied = copiedStaff(
                          part.staves[staffIndex], measureRange: measureRange, low: low, high: high,
                          division: score.division,
                      )
                else { continue }
                staves.append(copied)
            }
            guard !staves.isEmpty else { continue }
            parts.append(Part(
                id: part.id, trackName: part.trackName, instrument: part.instrument,
                staves: IdentifiedArray(staves), isVisibleInScore: part.isVisibleInScore,
            ))
        }
        guard !parts.isEmpty else { return nil }
        return Score(division: score.division, parts: IdentifiedArray(parts))
    }

    /// One staff reduced to the copied measures, renumbered from zero: the boundary measures (first and last)
    /// trimmed of the chords and rests the tick span does not cover, every other kept measure carried whole,
    /// and the time signature in force at the range's start made explicit if the kept measures do not already
    /// declare one of their own. `nil` when this staff does not have the whole measure range the tick span
    /// touches.
    private static func copiedStaff(
        _ staff: Staff, measureRange: ClosedRange<Int>, low: ScoreTickPosition, high: ScoreTickPosition,
        division: Int,
    ) -> Staff? {
        guard staff.measures.indices.contains(measureRange.lowerBound),
              staff.measures.indices.contains(measureRange.upperBound)
        else { return nil }

        let durations = staff.measures.effectiveMeasureDurations()
        var measures = measureRange.map { measureIndex in
            trimmedMeasure(
                staff.measures[measureIndex], measureIndex: measureIndex, measureDuration: durations[measureIndex],
                low: low, high: high, division: division,
            )
        }
        ensureLeadingTimeSignature(
            in: &measures, prevailing: prevailingTimeSignature(in: staff, upTo: measureRange.lowerBound),
        )

        var copied = staff
        copied.measures = measures
        // A bracket spans downward from this staff into siblings the payload may not carry, so it names a staff
        // this self-contained score no longer has.
        copied.brackets = []
        return copied
    }

    /// A kept measure, unchanged except at the range's own boundary: `measureIndex == low.measure` or
    /// `== high.measure` drops the chords and rests whose onset falls outside `low ..< high`, in every voice.
    /// Every non-timed element — clef, key/time signature, annotations — is kept regardless of its tick, which
    /// is what "leaving everything else" means: only the timed material is being clipped to the span.
    private static func trimmedMeasure(
        _ measure: Measure, measureIndex: Int, measureDuration: Fraction,
        low: ScoreTickPosition, high: ScoreTickPosition, division: Int,
    ) -> Measure {
        guard measureIndex == low.measure || measureIndex == high.measure else { return measure }
        var trimmed = measure
        trimmed.voices = measure.voices.map { voice in
            var tick = 0
            var kept: [VoiceElement] = []
            for element in voice.elements {
                defer { tick += element.cursorAdvance(division: division, in: measureDuration) }
                guard case .chord = element else {
                    kept.append(element)
                    continue
                }
                let position = ScoreTickPosition(measure: measureIndex, tick: tick)
                if position >= low, position < high {
                    kept.append(element)
                }
            }
            return Voice(elements: kept)
        }
        return trimmed
    }

    /// Inserts `.timeSignature(prevailing)` at the front of the first kept measure's first voice when no voice
    /// there already declares one. A range that starts mid-score inherits its meter from an earlier measure the
    /// payload does not carry, and a parser reading the payload alone — in another score, another window — has
    /// nothing else to resolve `.measure` durations against.
    private static func ensureLeadingTimeSignature(in measures: inout [Measure], prevailing: TimeSignature) {
        guard let first = measures.indices.first, measures[first].voices.indices.contains(0) else { return }
        let alreadyDeclared = measures[first].voices.contains { voice in
            voice.elements.contains { if case .timeSignature = $0 { true } else { false } }
        }
        guard !alreadyDeclared else { return }
        let leadingVoice = measures[first].voices[0]
        measures[first].voices[0] = Voice(elements: [.timeSignature(prevailing)] + Array(leadingVoice.elements))
    }

    /// The time signature carried forward to `measureIndex`, exactly the rule `[Measure].effectiveMeasureDurations()`
    /// uses to pick a prevailing `Fraction` — the first `.timeSignature` at or before `measureIndex`, defaulting to
    /// 4/4 when none has appeared yet.
    private static func prevailingTimeSignature(in staff: Staff, upTo measureIndex: Int) -> TimeSignature {
        var prevailing = TimeSignature(numerator: 4, denominator: 4)
        guard staff.measures.indices.contains(measureIndex) else { return prevailing }
        for measure in staff.measures[...measureIndex] {
            var found: TimeSignature?
            outer: for voice in measure.voices {
                for element in voice.elements {
                    if case let .timeSignature(timeSignature) = element {
                        found = timeSignature
                        break outer
                    }
                }
            }
            if let found { prevailing = found }
        }
        return prevailing
    }
}
