// swiftlint:disable file_length
import SheetMusicFoundation

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
/// - **disjoint** → keep the tuplet and its endpoint identities untouched.
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
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard !elements.isEmpty else {
            throw Self.refused(.emptyPayload)
        }
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw Self.refused(.targetNotFound(location))
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
            baseLocation: location, ids: &ids,
        )
        let replace = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: newTuplets,
        )
        return try replace.apply(to: &score, ids: &ids)
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
    /// tail, and retain surviving tuplets. Returns the new (elements,
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
        baseLocation: VoiceElementID, ids: inout EIDAllocator,
    ) throws -> (elements: IdentifiedArray<VoiceElement>, tuplets: IdentifiedArray<Tuplet>) {
        var newElements = voice.elements
        let pasted = payload.map { source in
            let eid = ids.next()
            var element = source.clearingGraceIDsForCopy()
            element.assignMissingNestedIDs(using: &ids)
            return (eid, element)
        }
        newElements.replaceSubrange(idx ..< (idx + 1), with: pasted)
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
                contentsOf: rests.map { (ids.next(), $0) }, at: payloadEndIdx + 1,
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
                    throw Self.refused(.blockedByUntimedElement(
                        at: baseLocation.withElementIndex(i),
                    ))
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
                throw Self.refused(.insufficientRoom(
                    neededTicks: needed,
                    availableTicks: consumed,
                ))
            }
            consumedEndOrigIdx = lastConsumedIdx - payloadInsertDelta

            try checkTupletOverlap(
                voice: voice,
                pasteStart: idx,
                pasteEnd: consumedEndOrigIdx,
                baseLocation: baseLocation,
            )

            newElements.removeSubrange(
                (payloadEndIdx + 1) ..< (lastConsumedIdx + 1),
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
                    contentsOf: pieces.map { (ids.next(), $0) }, at: payloadEndIdx + 1,
                )
            }
        }

        // For shorten / equal-duration paths only the target slot
        // changes — no consumption of subsequent elements. The
        // tuplet check still has to run because the target itself
        // might sit inside a tuplet.
        if payloadTicks <= targetTicks {
            try checkTupletOverlap(
                voice: voice,
                pasteStart: idx,
                pasteEnd: idx,
                baseLocation: baseLocation,
            )
        }

        var adjustedTuplets = voice.tuplets
        for (index, span) in voice.tupletSpans.enumerated().reversed() {
            // The overlap check above permits only whole-tuplet consumption.
            if idx <= span.endIndex, span.startIndex <= consumedEndOrigIdx {
                adjustedTuplets.remove(eid: voice.tuplets.eid(at: index))
            }
        }
        return (newElements, adjustedTuplets)
    }

    /// Refuse the paste when its element range
    /// `[pasteStart, pasteEnd]` overlaps any tuplet without fully
    /// containing it. The full-contain case is allowed (the tuplet
    /// is dropped wholesale by the caller).
    private static func checkTupletOverlap(
        voice: Voice,
        pasteStart: Int,
        pasteEnd: Int,
        baseLocation: VoiceElementID,
    ) throws {
        for t in voice.tupletSpans {
            let overlap = pasteStart <= t.endIndex
                && t.startIndex <= pasteEnd
            if !overlap { continue }
            let fullyContained = pasteStart <= t.startIndex
                && t.endIndex <= pasteEnd
            if !fullyContained {
                throw Self.refused(.tupletOverlap(
                    rangeStart: pasteStart,
                    rangeEnd: pasteEnd,
                    tupletStart: t.startIndex,
                    tupletEnd: t.endIndex,
                ))
            }
        }
    }
}
