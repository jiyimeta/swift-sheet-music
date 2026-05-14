// swiftlint:disable file_length
import Foundation

/// Multi-element paste: replace the single element at `location`
/// with a sequence of `elements`, then rebalance the voice's
/// element list so the measure's tick total stays the same. Used
/// by range copy / paste in the editor — the `elements` payload is
/// the slice that was copied from a contiguous region of the
/// source voice.
///
/// Rebalance rules (mirroring `PasteVoiceElement` and
/// `SetChordDuration`):
/// - **payload shorter than target** → fill the leftover with
///   beat-aligned rests after the spliced range.
/// - **payload longer than target** → consume following chord /
///   rest elements until enough time is freed; an overshot final
///   chord becomes a tied-clone chain.
///
/// Tuplet handling: the paste's element-index range is
/// `[location, consumedEnd]`. For each tuplet of the destination
/// voice we check that range vs. the tuplet's own indices:
/// - **disjoint** → keep the tuplet untouched (just shift indices
///   to account for net element count change).
/// - **paste fully contains the tuplet** → drop the tuplet (the
///   triplet/quintuplet/… is replaced wholesale).
/// - **partial overlap** → refuse with `invalidEdit` (would split
///   the tuplet, invalidating its ratio).
///
/// Other refusals: lengthen path runs into a non-timed element, or
/// runs out of room before reaching the required tick count.
///
/// Inverse is a `ReplaceVoiceElements` carrying the pre-edit voice
/// (elements + tuplets), so undo restores the entire voice in one
/// step.
public struct PasteVoiceElements: EditCommand {
    public let location: VoiceElementID
    public let elements: [VoiceElement]

    public init(
        at location: VoiceElementID,
        elements: [VoiceElement],
    ) {
        self.location = location
        self.elements = elements
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard !elements.isEmpty else {
            throw SheetMusicError.invalidEdit(
                reason: "PasteVoiceElements: payload is empty",
            )
        }
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "PasteVoiceElements: no element at \(location)",
            )
        }
        let division = score.division
        let measureDuration = score
            .effectiveMeasureDurations(
                partIndex: location.staff.partIndex,
                staffIndex: location.staff.staffIndexInPart,
            )[location.measureIndex]
        let target = voice.elements[location.elementIndex]
        let targetTicks = Self.ticks(
            of: target, division: division, measureDuration: measureDuration,
        ) ?? 0
        let payloadTicks = elements.reduce(0) {
            $0 + (Self.ticks(
                of: $1, division: division, measureDuration: measureDuration,
            ) ?? 0)
        }
        let targetRtick = DurationChangeAlgorithm.tickOffset(
            in: voice,
            ofElementAt: location.elementIndex,
            division: division,
        )
        let (newElements, newTuplets) = try Self.computeRebalanced(
            voice: voice,
            atIdx: location.elementIndex,
            payload: elements,
            payloadTicks: payloadTicks,
            targetTicks: targetTicks,
            targetRtick: targetRtick,
            division: division,
            measureDuration: measureDuration,
        )
        let replace = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: newTuplets,
        )
        return try replace.apply(to: &score)
    }

    private static func ticks(
        of element: VoiceElement,
        division: Int,
        measureDuration: Fraction,
    ) -> Int? {
        switch element {
        case let .chord(c):
            return c.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
        default: return nil
        }
    }

    /// Splice the payload into the voice at `idx`, rebalance the
    /// tail, and adjust tuplet indices. Returns the new (elements,
    /// tuplets) pair. Throws on partial-overlap with any tuplet
    /// (the user must clear the tuplet first or paste at a different
    /// location).
    private static func computeRebalanced( // swiftlint:disable:this function_body_length
        voice: Voice,
        atIdx idx: Int,
        payload: [VoiceElement],
        payloadTicks: Int,
        targetTicks: Int,
        targetRtick: Int,
        division: Int,
        measureDuration: Fraction,
    ) throws -> (elements: [VoiceElement], tuplets: [Tuplet]) {
        var newElements = voice.elements
        newElements.replaceSubrange(idx ... idx, with: payload)
        let payloadEndIdx = idx + payload.count - 1
        let payloadInsertDelta = payload.count - 1
        // The paste's effective element-index range in the ORIGINAL
        // voice, i.e. which elements of voice.elements get replaced
        // or consumed. Always at least `[idx, idx]` (the target).
        var consumedEndOrigIdx = idx

        if payloadTicks < targetTicks {
            let leftover = targetTicks - payloadTicks
            let rests = DurationChangeAlgorithm.alignedRests(
                forTicks: leftover,
                rtickStart: targetRtick + payloadTicks,
                division: division,
            )
            newElements.insert(
                contentsOf: rests, at: payloadEndIdx + 1,
            )
        } else if payloadTicks > targetTicks {
            let needed = payloadTicks - targetTicks
            var consumed = 0
            var lastConsumedIdx = payloadEndIdx
            var partial = 0
            var lastConsumedEl: VoiceElement?
            var i = payloadEndIdx + 1
            while i < newElements.count {
                let elTicks: Int
                switch newElements[i] {
                case let .chord(c):
                    elTicks = c.duration
                        .resolved(in: measureDuration)
                        .ticks(division: division)
                default:
                    throw SheetMusicError.invalidEdit(
                        reason: "PasteVoiceElements: lengthening "
                            + "blocked by non-timed element at "
                            + "index \(i)",
                    )
                }
                if consumed + elTicks <= needed {
                    consumed += elTicks
                    lastConsumedIdx = i
                    lastConsumedEl = newElements[i]
                    i += 1
                    if consumed == needed { break }
                } else {
                    partial = (consumed + elTicks) - needed
                    consumed = needed
                    lastConsumedIdx = i
                    lastConsumedEl = newElements[i]
                    break
                }
            }
            if consumed < needed {
                throw SheetMusicError.invalidEdit(
                    reason: "PasteVoiceElements: not enough room "
                        + "in the measure to lengthen "
                        + "(need \(needed), have \(consumed))",
                )
            }
            consumedEndOrigIdx = lastConsumedIdx - payloadInsertDelta

            try checkTupletOverlap(
                voice: voice,
                pasteStart: idx,
                pasteEnd: consumedEndOrigIdx,
            )

            newElements.removeSubrange(
                (payloadEndIdx + 1) ... lastConsumedIdx,
            )
            if partial > 0, let lastEl = lastConsumedEl {
                let durations = DurationChangeAlgorithm.alignedDurations(
                    forTicks: partial,
                    rtickStart: targetRtick + payloadTicks,
                    division: division,
                )
                let pieces: [VoiceElement]
                switch lastEl {
                case let .chord(c) where !c.notes.isEmpty:
                    pieces = DurationChangeAlgorithm.makeChordChain(
                        from: c, durations: durations,
                    )
                default:
                    pieces = durations.map { .rest(duration: $0) }
                }
                newElements.insert(
                    contentsOf: pieces, at: payloadEndIdx + 1,
                )
            }
        }

        // For shorten / equal-duration paths only the target slot
        // changes — no consumption of subsequent elements. The
        // tuplet check still has to run because the target itself
        // might sit inside a tuplet.
        if payloadTicks <= targetTicks {
            try checkTupletOverlap(
                voice: voice, pasteStart: idx, pasteEnd: idx,
            )
        }

        let netDelta = newElements.count - voice.elements.count
        let adjustedTuplets: [Tuplet] = voice.tuplets.compactMap { t in
            let overlapsPaste = idx <= t.endIndex
                && t.startIndex <= consumedEndOrigIdx
            if !overlapsPaste {
                // Disjoint with the paste range. Either entirely
                // before (keep verbatim) or entirely after (shift
                // indices by net element-count change).
                if t.startIndex > consumedEndOrigIdx {
                    return Tuplet(
                        normalNotes: t.normalNotes,
                        actualNotes: t.actualNotes,
                        startIndex: t.startIndex + netDelta,
                        endIndex: t.endIndex + netDelta,
                    )
                }
                return t
            }
            // Verified above (`checkTupletOverlap`) that the paste
            // fully contains overlapping tuplets. Drop them.
            return nil
        }
        return (newElements, adjustedTuplets)
    }

    /// Refuse the paste when its element range
    /// `[pasteStart, pasteEnd]` overlaps any tuplet without fully
    /// containing it. The full-contain case is allowed (the tuplet
    /// is dropped wholesale by the caller).
    private static func checkTupletOverlap(
        voice: Voice, pasteStart: Int, pasteEnd: Int,
    ) throws {
        for t in voice.tuplets {
            let overlap = pasteStart <= t.endIndex
                && t.startIndex <= pasteEnd
            if !overlap { continue }
            let fullyContained = pasteStart <= t.startIndex
                && t.endIndex <= pasteEnd
            if !fullyContained {
                throw SheetMusicError.invalidEdit(
                    reason: "PasteVoiceElements: paste range "
                        + "[\(pasteStart)…\(pasteEnd)] would "
                        + "partially overlap a tuplet "
                        + "[\(t.startIndex)…\(t.endIndex)] — "
                        + "would invalidate its ratio",
                )
            }
        }
    }
}
