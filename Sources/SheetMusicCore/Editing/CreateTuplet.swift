// swiftlint:disable function_body_length file_length
import Foundation

/// Convert a single chord or rest into a tuplet of `actualNotes`
/// members (e.g. `actualNotes = 3`, `normalNotes = 2` for a
/// triplet — three notes in the time of two).
///
/// The target's tick span stays the same. Each new member's stored
/// duration is `original / actualNotes` (a fractional duration the
/// layout reads as the matching power-of-two glyph + tuplet
/// bracket). The first member inherits the original chord's notes,
/// arpeggio, and lyrics; remaining members are rests. A `Tuplet`
/// entry is added to `Voice.tuplets` covering the new members.
///
/// Refused when:
/// - the target sits inside an existing tuplet (no nesting),
/// - the target isn't a chord or rest (non-timed elements have no
///   duration to subdivide),
/// - the target's tick count doesn't divide evenly by
///   `actualNotes` (the resulting fraction would be irrational
///   for our purposes — happens e.g. on a duration that already
///   carries an unusual fraction).
///
/// Inverse is a `ReplaceVoiceElements` carrying the pre-edit
/// `elements` and `tuplets`, so undo is bit-perfect.
public struct CreateTuplet: EditCommand {
    public let location: VoiceElementID
    /// "N actual notes" — number of members printed in the bracket.
    public let actualNotes: Int
    /// "in the time of N normal notes" — the unscaled denominator.
    public let normalNotes: Int

    public init(
        at location: VoiceElementID,
        actualNotes: Int,
        normalNotes: Int,
    ) {
        precondition(
            actualNotes > 1,
            "CreateTuplet: actualNotes must be > 1",
        )
        precondition(
            normalNotes > 0,
            "CreateTuplet: normalNotes must be > 0",
        )
        self.location = location
        self.actualNotes = actualNotes
        self.normalNotes = normalNotes
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
                reason: "CreateTuplet: no element at \(location)",
            )
        }
        if voice.tuplets.contains(where: {
            $0.startIndex <= location.elementIndex
                && location.elementIndex <= $0.endIndex
        }) {
            throw SheetMusicError.invalidEdit(
                reason: "CreateTuplet: target at \(location) "
                    + "already sits inside another tuplet",
            )
        }
        guard case let .chord(target)
            = voice.elements[location.elementIndex]
        else {
            throw SheetMusicError.invalidEdit(
                reason: "CreateTuplet: target at \(location) "
                    + "is not a chord or rest",
            )
        }
        let division = score.division
        let targetTicks = target.duration.ticks(division: division)
        guard targetTicks % actualNotes == 0 else {
            throw SheetMusicError.invalidEdit(
                reason: "CreateTuplet: target's \(targetTicks) "
                    + "ticks don't divide evenly into "
                    + "\(actualNotes) members",
            )
        }
        let memberTicks = targetTicks / actualNotes
        let memberDuration: NoteDuration = .fraction(Fraction(
            numerator: memberTicks,
            denominator: 4 * division,
        ))

        // Build the member sequence. The first one carries the
        // target's chord content (or stays a rest if the target was
        // empty); the remainder are rests of the same duration.
        var members: [VoiceElement] = []
        for i in 0 ..< actualNotes {
            if i == 0 && !target.notes.isEmpty {
                var copy = target
                copy.duration = memberDuration
                members.append(.chord(copy))
            } else {
                members.append(.rest(duration: memberDuration))
            }
        }

        var newElements = voice.elements
        newElements.replaceSubrange(
            location.elementIndex ... location.elementIndex,
            with: members,
        )

        // Tuplets entirely past the spliced region shift by the
        // net element-count change; tuplets entirely before stay
        // put. The earlier guard ensured no existing tuplet
        // overlaps the target, so partial-overlap can't occur.
        let netDelta = actualNotes - 1
        var newTuplets: [Tuplet] = voice.tuplets.map { t in
            if t.startIndex > location.elementIndex {
                return Tuplet(
                    normalNotes: t.normalNotes,
                    actualNotes: t.actualNotes,
                    startIndex: t.startIndex + netDelta,
                    endIndex: t.endIndex + netDelta,
                )
            }
            return t
        }
        newTuplets.append(Tuplet(
            normalNotes: normalNotes,
            actualNotes: actualNotes,
            startIndex: location.elementIndex,
            endIndex: location.elementIndex + actualNotes - 1,
        ))
        // Sort by startIndex so downstream code that assumes ordered
        // tuplets doesn't break.
        newTuplets.sort { $0.startIndex < $1.startIndex }

        let replace = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: newTuplets,
        )
        return try replace.apply(to: &score)
    }
}
