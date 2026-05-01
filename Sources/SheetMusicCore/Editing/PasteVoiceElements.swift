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
/// Refused (with `invalidEdit`):
/// - the target sits inside (or before, with overlap) a `Tuplet` —
///   v1 does not handle tuplet rebalancing across multi-element
///   splices.
/// - the lengthen path runs into a non-timed element or out of
///   measure room.
///
/// Inverse is a `ReplaceVoiceElements` carrying the pre-edit voice,
/// so undo restores the entire voice in one step.
public struct PasteVoiceElements: EditCommand {
    public let location: VoiceElementID
    public let elements: [VoiceElement]

    public init(
        at location: VoiceElementID,
        elements: [VoiceElement]
    ) {
        self.location = location
        self.elements = elements
    }

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard !elements.isEmpty else {
            throw SheetMusicError.invalidEdit(
                reason: "PasteVoiceElements: payload is empty")
        }
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
              voice.elements.indices.contains(location.elementIndex)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "PasteVoiceElements: no element at \(location)")
        }
        // v1 limitation: refuse when any tuplet of the destination
        // voice extends to or past the target. Multi-element splice
        // through a tuplet would need bespoke rebalance logic.
        if voice.tuplets.contains(where: {
            $0.endIndex >= location.elementIndex
        }) {
            throw SheetMusicError.invalidEdit(
                reason: "PasteVoiceElements: destination voice has "
                    + "a tuplet at or after the paste location")
        }
        let division = score.division
        let target = voice.elements[location.elementIndex]
        let targetTicks = Self.ticks(of: target, division: division) ?? 0
        let payloadTicks = elements.reduce(0) {
            $0 + (Self.ticks(of: $1, division: division) ?? 0)
        }
        let targetRtick = DurationChangeAlgorithm.tickOffset(
            in: voice,
            ofElementAt: location.elementIndex,
            division: division)
        let newElements = try Self.computeRebalanced(
            voice: voice,
            atIdx: location.elementIndex,
            payload: elements,
            payloadTicks: payloadTicks,
            targetTicks: targetTicks,
            targetRtick: targetRtick,
            division: division)
        let replace = ReplaceVoiceElements(
            staffIndex: location.staffIndex,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: voice.tuplets)
        return try replace.apply(to: &score)
    }

    private static func ticks(
        of element: VoiceElement, division: Int
    ) -> Int? {
        switch element {
        case .chord(let c): return c.duration.ticks(division: division)
        case .rest(let r):  return r.duration.ticks(division: division)
        default: return nil
        }
    }

    /// Splice the payload into the voice at `idx` (replacing the
    /// single target there), then rebalance the tail so the measure's
    /// tick total is unchanged. Mirrors the shorten / lengthen split
    /// in `DurationChangeAlgorithm.compute` but for a multi-element
    /// inserted region. v1 ignores tuplets — the caller has already
    /// refused the operation when any tuplet would interfere.
    private static func computeRebalanced(
        voice: Voice,
        atIdx idx: Int,
        payload: [VoiceElement],
        payloadTicks: Int,
        targetTicks: Int,
        targetRtick: Int,
        division: Int
    ) throws -> [VoiceElement] {
        var newElements = voice.elements
        newElements.replaceSubrange(idx...idx, with: payload)
        let payloadEndIdx = idx + payload.count - 1
        if payloadTicks < targetTicks {
            let leftover = targetTicks - payloadTicks
            let rests = DurationChangeAlgorithm.alignedRests(
                forTicks: leftover,
                rtickStart: targetRtick + payloadTicks,
                division: division)
            newElements.insert(
                contentsOf: rests, at: payloadEndIdx + 1)
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
                case .chord(let c):
                    elTicks = c.duration.ticks(division: division)
                case .rest(let r):
                    elTicks = r.duration.ticks(division: division)
                default:
                    throw SheetMusicError.invalidEdit(
                        reason: "PasteVoiceElements: lengthening "
                            + "blocked by non-timed element at "
                            + "index \(i)")
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
                        + "(need \(needed), have \(consumed))")
            }
            newElements.removeSubrange(
                (payloadEndIdx + 1)...lastConsumedIdx)
            if partial > 0, let lastConsumedEl {
                let durations = DurationChangeAlgorithm.alignedDurations(
                    forTicks: partial,
                    rtickStart: targetRtick + payloadTicks,
                    division: division)
                let pieces: [VoiceElement]
                switch lastConsumedEl {
                case .chord(let c):
                    pieces = DurationChangeAlgorithm.makeChordChain(
                        from: c, durations: durations)
                default:
                    pieces = durations.map {
                        .rest(Rest(duration: $0))
                    }
                }
                newElements.insert(
                    contentsOf: pieces, at: payloadEndIdx + 1)
            }
        }
        return newElements
    }
}
