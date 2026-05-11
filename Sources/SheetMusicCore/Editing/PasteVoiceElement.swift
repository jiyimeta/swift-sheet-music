import Foundation

/// Replace the element at `location` with `element`, rebalancing
/// the voice when the durations differ. Same algorithm
/// `SetChordDuration` uses for its lengthen / shorten paths
/// (`DurationChangeAlgorithm.compute`):
///
/// - source shorter than target → fill the leftover with
///   beat-aligned rests after the pasted element.
/// - source longer than target → consume following chord / rest
///   elements until the new duration is satisfied; an overshot
///   chord gets a tied-clone chain, an overshot tuplet gets
///   torn down whole.
///
/// Refused (with `invalidEdit`):
/// - target sits inside a `Tuplet` span
/// - source ticks exceed what the rest of the measure can yield
/// - lengthen path runs into a non-timed element (clef / key
///   sig / barline / …)
///
/// Inverse is a `ReplaceVoiceElements` carrying the prior
/// `elements` and `tuplets`, so undo restores the voice verbatim
/// even after a multi-element rebalance.
public struct PasteVoiceElement: EditCommand {
    public let location: VoiceElementID
    public let element: VoiceElement

    public init(at location: VoiceElementID, element: VoiceElement) {
        self.location = location
        self.element = element
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "PasteVoiceElement: no element at \(location)",
            )
        }
        let original = voice.elements[location.elementIndex]
        let division = score.division
        let srcTicks = Self.ticks(of: element, division: division)
        let dstTicks = Self.ticks(of: original, division: division)

        // Non-timed source or target: degenerate to a verbatim swap
        // — there's no tick obligation to balance and no following
        // elements to consume from.
        guard let src = srcTicks, let dst = dstTicks else {
            score[location] = element
            return ReplaceVoiceElement(at: location, with: original)
        }
        // Same duration: still a verbatim swap, no rebalance needed.
        if src == dst {
            score[location] = element
            return ReplaceVoiceElement(at: location, with: original)
        }
        // Different durations — defer to the shorten / lengthen
        // algorithm.  Refuse first when the target is inside a
        // tuplet (changing its duration would invalidate the ratio).
        try DurationChangeAlgorithm.ensureNotInsideTuplet(
            voice: voice,
            elementIdx: location.elementIndex,
            label: "PasteVoiceElement",
        )
        let targetRtick = DurationChangeAlgorithm.tickOffset(
            in: voice,
            ofElementAt: location.elementIndex,
            division: division,
        )
        // `srcTicks` in DurationChangeAlgorithm = the OLD duration
        // at idx (i.e., the target we're replacing); `dstTicks` =
        // the NEW duration (i.e., the pasted element).
        let (newElements, newTuplets) = try DurationChangeAlgorithm
            .compute(
                in: voice,
                atIdx: location.elementIndex,
                mutatedTarget: element,
                srcTicks: dst,
                dstTicks: src,
                targetRtick: targetRtick,
                division: division,
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

    /// Tick count of a chord / rest; nil for non-timed elements
    /// so the duration check is skipped for those.
    private static func ticks(
        of element: VoiceElement, division: Int,
    ) -> Int? {
        switch element {
        case let .chord(c): return c.duration.ticks(division: division)
        default: return nil
        }
    }
}
