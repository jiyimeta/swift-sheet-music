// swiftlint:disable file_length
import SheetMusicFoundation

/// Drop the tuplet that contains the element at `location` and
/// replace its members with a single chord/rest of the same total
/// tick span.
///
/// Behavior:
/// - First-member-with-notes case → a single `Chord` carrying the
///   first member's notes / arpeggio / lyrics, with duration equal
///   to the tuplet's total tick span.
/// - Otherwise → a single rest of the tuplet's total tick span.
///
/// Other members (their notes, ties, lyrics) are dropped — same
/// "best effort, single replacement" shape MuseScore uses for
/// `cmdDeleteTuplet`. Use `Cut` first if you need to preserve the
/// content elsewhere.
///
/// Refused when `location.elementIndex` doesn't sit inside any
/// tuplet of the destination voice.
///
/// Inverse is a `ReplaceVoiceElements` carrying the pre-edit
/// `elements` and `tuplets`, so undo is bit-perfect.
public struct RemoveTuplet: EditCommand {
    public let location: VoiceElementID

    public init(at location: VoiceElementID) {
        self.location = location
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw Self.refused(.targetNotFound(location))
        }
        guard let tuplet = voice.tupletSpans.first(where: {
            $0.startIndex <= location.elementIndex
                && location.elementIndex <= $0.endIndex
        }) else {
            throw Self.refused(.wrongElementKind(at: location, expected: .tuplet))
        }
        let division = score.division
        var totalTicks = 0
        for j in tuplet.startIndex ... tuplet.endIndex {
            switch voice.elements[j] {
            case let .chord(c):
                totalTicks += c.duration.ticks(division: division)
            default:
                continue
            }
        }
        let totalDuration: NoteDuration = .fraction(Fraction(
            numerator: totalTicks, denominator: 4 * division,
        ))
        // Pick the first chord with notes (if any) inside the
        // tuplet — its content survives in the single replacement
        // element. Otherwise the replacement is a plain rest.
        let sourceIndex = (tuplet.startIndex ... tuplet.endIndex).first { index in
            if case let .chord(chord) = voice.elements[index] { return !chord.notes.isEmpty }
            return false
        } ?? tuplet.startIndex
        let replacement: VoiceElement
        if let firstChord = (tuplet.startIndex ... tuplet.endIndex)
            .compactMap({ idx -> Chord? in
                if case let .chord(c) = voice.elements[idx],
                   !c.notes.isEmpty { return c }
                return nil
            })
            .first
        {
            var copy = firstChord
            copy.duration = totalDuration
            replacement = .chord(copy)
        } else {
            replacement = .rest(duration: totalDuration)
        }

        var changed = voice
        // Preserve the existing same-span removal rule, including duplicate entries.
        for (index, span) in voice.tupletSpans.enumerated().reversed() {
            if span.startIndex == tuplet.startIndex, span.endIndex == tuplet.endIndex {
                changed.tuplets.remove(eid: voice.tuplets.eid(at: index))
            }
        }
        changed.replaceElement(at: sourceIndex, with: replacement, id: voice.elements.eid(at: sourceIndex))
        let removed = Set((tuplet.startIndex ... tuplet.endIndex).filter { $0 != sourceIndex })
        changed.removeElements(at: removed)

        let replace = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: changed.elements,
            tuplets: changed.tuplets,
        )
        return try replace.apply(to: &score, ids: &ids)
    }
}
