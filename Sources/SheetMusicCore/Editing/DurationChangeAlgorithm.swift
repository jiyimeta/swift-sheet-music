// swiftlint:disable file_length
import SheetMusicFoundation

/// Shared shorten / lengthen algorithm used by `SetChordDuration`
/// and `SetRestDuration`. Both commands resolve to "change the
/// duration of a timed element at index L; rebalance the rest of
/// the voice so the measure's tick total stays the same"; the only
/// difference between them is which element kind they expect at L.
public enum DurationChangeAlgorithm {
    /// Inputs and outputs:
    /// - `voice`: the voice to recompute.
    /// - `idx`: index in `voice.elements` of the element being
    ///   changed.
    /// - `mutatedTarget`: the element after duration mutation
    ///   (caller has already replaced its duration).
    /// - `srcTicks` / `dstTicks`: old / new duration in ticks.
    /// - `targetRtick`: tick offset of `idx` within the measure.
    /// - `division`: score PPQ (`Score.division`).
    /// - returns: the recomputed `elements` + tuplet list (with any
    ///   tuplet ranges past `idx` shifted by the net change in
    ///   element count).
    /// - throws: `SheetMusicError.invalidEdit` when the change would
    ///   cross a measure boundary, consume past a non-timed element,
    ///   or overlap a downstream tuplet.
    static func compute( // swiftlint:disable:this function_body_length
        in voice: Voice,
        atIdx idx: Int,
        mutatedTarget: VoiceElement,
        srcTicks: Int,
        dstTicks: Int,
        targetRtick: Int,
        division: Int,
        baseLocation: VoiceElementID,
        operation: String,
    ) throws -> (elements: [VoiceElement], tuplets: [Tuplet]) {
        var newElements = voice.elements
        newElements[idx] = mutatedTarget
        // For shortening, no consumption happens — `consumedEndIdx`
        // stays at `idx` so the post-loop tuplet adjustment treats
        // every downstream tuplet as "after the modified region"
        // and just shifts it by the inserted-rest delta.
        var consumedEndIdx = idx
        if dstTicks < srcTicks {
            let leftover = srcTicks - dstTicks
            let rests = alignedRests(
                forTicks: leftover,
                rtickStart: targetRtick + dstTicks,
                division: division,
            )
            newElements.insert(contentsOf: rests, at: idx + 1)
        } else if dstTicks > srcTicks {
            let needed = dstTicks - srcTicks
            var consumed = 0
            var lastConsumedIdx = idx
            var partial = 0
            // When the last consumed unit was a whole tuplet that we
            // tore down (MuseScore's `cmdDeleteTuplet` branch), the
            // overshoot becomes plain rests — not tied chord clones —
            // because there's no single chord whose pitch we should
            // preserve. Plain non-tuplet chord overshoot still emits
            // a tied clone chain.
            var lastConsumedWasTuplet = false
            var i = idx + 1
            while i < newElements.count {
                // If `i` falls inside any tuplet, swallow the whole
                // tuplet at once (MuseScore mirrors this in
                // `makeGap` -- entering a tuplet deletes it
                // wholesale, the gap accumulates the tuplet's full
                // tick length, and the overshoot is filled with
                // rests via `setRest`).
                if let containing = voice.tuplets.first(where: {
                    $0.startIndex <= i && i <= $0.endIndex
                }) {
                    var tupletTicks = 0
                    for j in containing.startIndex ... containing.endIndex {
                        switch newElements[j] {
                        case let .chord(c):
                            tupletTicks += c.duration.ticks(
                                division: division,
                            )
                        // Rests are empty chords, picked up by the
                        // .chord case above.
                        default:
                            continue
                        }
                    }
                    if consumed + tupletTicks <= needed {
                        consumed += tupletTicks
                        lastConsumedIdx = containing.endIndex
                        lastConsumedWasTuplet = true
                        i = containing.endIndex + 1
                        if consumed == needed { break }
                        continue
                    } else {
                        partial = (consumed + tupletTicks) - needed
                        consumed = needed
                        lastConsumedIdx = containing.endIndex
                        lastConsumedWasTuplet = true
                        break
                    }
                }
                let elTicks: Int
                switch newElements[i] {
                case let .chord(c):
                    elTicks = c.duration.ticks(division: division)
                default:
                    throw SheetMusicError.invalidEdit(EditRefusal(
                        operation: operation,
                        reason: .blockedByUntimedElement(
                            at: baseLocation.withElementIndex(i),
                        ),
                    ))
                }
                if consumed + elTicks <= needed {
                    consumed += elTicks
                    lastConsumedIdx = i
                    i += 1
                    if consumed == needed { break }
                } else {
                    partial = (consumed + elTicks) - needed
                    consumed = needed
                    lastConsumedIdx = i
                    break
                }
            }
            if consumed < needed {
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: operation,
                    reason: .insufficientRoom(
                        neededTicks: needed,
                        availableTicks: consumed,
                    ),
                ))
            }
            consumedEndIdx = lastConsumedIdx
            let lastEl = newElements[lastConsumedIdx]
            newElements.removeSubrange((idx + 1) ... lastConsumedIdx)
            if partial > 0 {
                let durations = alignedDurations(
                    forTicks: partial,
                    rtickStart: targetRtick + dstTicks,
                    division: division,
                )
                let pieces: [VoiceElement]
                if lastConsumedWasTuplet {
                    pieces = durations.map {
                        .rest(duration: $0)
                    }
                } else {
                    switch lastEl {
                    case let .chord(consumedChord)
                        where !consumedChord.notes.isEmpty:
                        pieces = makeChordChain(
                            from: consumedChord, durations: durations,
                        )
                    default:
                        // Rest overshoot (or empty chord) — leftover
                        // is plain rests, no tied chain.
                        pieces = durations.map {
                            .rest(duration: $0)
                        }
                    }
                }
                newElements.insert(
                    contentsOf: pieces, at: idx + 1,
                )
            }
        }
        let netDelta = newElements.count - voice.elements.count
        // Tuplets entirely inside the consumed range are gone (we
        // tore them down whole during the lengthen walk); ones
        // strictly past the consumed tail shift by the net change in
        // element count; ones before stay put.
        let adjustedTuplets: [Tuplet] = voice.tuplets.compactMap { t in
            if t.endIndex < idx + 1 {
                return t
            }
            if t.startIndex >= idx + 1
                && t.endIndex <= consumedEndIdx
            {
                return nil
            }
            if t.startIndex > consumedEndIdx {
                return Tuplet(
                    normalNotes: t.normalNotes,
                    actualNotes: t.actualNotes,
                    startIndex: t.startIndex + netDelta,
                    endIndex: t.endIndex + netDelta,
                )
            }
            // Partial overlap — should not occur given our
            // tuplet-as-unit consumption rule.
            return nil
        }
        return (newElements, adjustedTuplets)
    }

    /// Tick offset of `voice.elements[idx]` from the start of its
    /// measure. Sums durations of preceding chord/rest elements;
    /// non-timed elements (clef, key sig, ...) don't advance the
    /// cursor.
    static func tickOffset(
        in voice: Voice, ofElementAt idx: Int, division: Int,
    ) -> Int {
        var t = 0
        for i in 0 ..< min(idx, voice.elements.count) {
            switch voice.elements[i] {
            case let .chord(c):
                t += c.duration.ticks(division: division)
            default:
                continue
            }
        }
        return t
    }

    /// Beat-aligned decomposition of a `length`-tick gap starting at
    /// `rtickStart` (offset within its measure). Mirrors MuseScore's
    /// `populateRhythmicList` (`durationtype.cpp`): each emitted
    /// duration is the largest power-of-two duration `D` such that
    /// `D <= remaining` AND `currentRtick % D == 0`. The alignment
    /// rule produces e.g. `eighth + quarter + half` — not greedy
    /// `half + quarter + eighth` — for a whole shortened to an
    /// eighth at beat 1.
    public static func alignedDurations(
        forTicks length: Int,
        rtickStart: Int,
        division: Int,
    ) -> [NoteDuration] {
        var result: [NoteDuration] = []
        var rtick = rtickStart
        var remaining = length
        let candidates: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth,
            .thirtySecond, .sixtyFourth,
            .oneTwentyEighth, .twoFiftySixth,
        ]
        while remaining > 0 {
            var picked: NoteDuration?
            for c in candidates {
                let d = c.ticks(division: division)
                if d > 0 && d <= remaining && rtick % d == 0 {
                    picked = c
                    break
                }
            }
            guard let pick = picked else {
                result.append(.fraction(Fraction(
                    numerator: remaining,
                    denominator: division * 4,
                )))
                break
            }
            result.append(pick)
            let dt = pick.ticks(division: division)
            rtick += dt
            remaining -= dt
        }
        return result
    }

    public static func alignedRests(
        forTicks length: Int,
        rtickStart: Int,
        division: Int,
    ) -> [VoiceElement] {
        alignedDurations(
            forTicks: length, rtickStart: rtickStart,
            division: division,
        ).map { .rest(duration: $0) }
    }

    public static func makeChordChain(
        from src: Chord, durations: [NoteDuration],
    ) -> [VoiceElement] {
        guard !durations.isEmpty else { return [] }
        var pieces: [VoiceElement] = []
        for (idx, dur) in durations.enumerated() {
            let isFirst = idx == 0
            let isLast = idx == durations.count - 1
            var notes = src.notes
            for ni in notes.indices {
                notes[ni].tieBack = isFirst ? nil : 1
                notes[ni].tieForward = isLast
                    ? src.notes[ni].tieForward
                    : 1
            }
            pieces.append(.chord(Chord(
                duration: dur,
                notes: notes,
                arpeggio: isFirst ? src.arpeggio : nil,
                lyrics: isFirst ? src.lyrics : [],
            )))
        }
        return pieces
    }

    /// Find the voice at the given location, returning nil when the
    /// indices are out of range. Shared by both commands.
    static func voice(
        in score: Score, at id: VoiceElementID,
    ) -> Voice? {
        guard score.parts.indices.contains(id.staff.partIndex),
              score.parts[id.staff.partIndex].staves.indices
                  .contains(id.staff.staffIndexInPart)
        else { return nil }
        let measures = score.parts[id.staff.partIndex]
            .staves[id.staff.staffIndexInPart].measures
        guard measures.indices.contains(id.measureIndex) else {
            return nil
        }
        let voices = measures[id.measureIndex].voices
        guard voices.indices.contains(id.voiceIndex) else { return nil }
        return voices[id.voiceIndex]
    }

    /// Common precondition: refuse when the target element sits
    /// inside any tuplet span.
    static func ensureNotInsideTuplet(
        voice: Voice,
        at location: VoiceElementID,
        operation: String,
    ) throws {
        if voice.tuplets.contains(where: {
            $0.startIndex <= location.elementIndex
                && location.elementIndex <= $0.endIndex
        }) {
            throw SheetMusicError.invalidEdit(
                EditRefusal(
                    operation: operation,
                    reason: .insideTuplet(at: location),
                ),
            )
        }
    }
}
