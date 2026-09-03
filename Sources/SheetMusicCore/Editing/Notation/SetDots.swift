import SheetMusicFoundation

/// Set the number of augmentation dots on a chord or rest — MuseScore's `.` key.
///
/// It owns no rhythm arithmetic of its own. The slot's current length is decomposed into the base and dot count it
/// was built from (`NoteDuration.baseAndDots()`), the new length is `base.dotted(dots)`, and the write is delegated
/// to `SetChordDuration` or `SetRestDuration` — so shortening leaves beat-aligned rests, lengthening consumes the
/// following elements and tied-clones a partly consumed chord, and every refusal those two make (`.insideTuplet`,
/// `.insufficientRoom`, `.blockedByUntimedElement`, `.tupletOverlap`) surfaces from here unchanged. The inverse is
/// theirs too, so undo is bit-perfect.
///
/// `.notDottable` is what this command adds: a length with no dotted spelling (a `.measure` rest, a tuplet-scaled
/// `.fraction`) or a count outside the 0…3 this package writes. `dots: 0` is a real value — it removes the dots.
///
/// The delegated command raises its refusals under its OWN operation name (`"SetChordDuration"` /
/// `"SetRestDuration"`) rather than `"SetDots"`. That is deliberate: the refusal names the rule that fired, which
/// is what a triage reader needs.
///
/// > Note: This command is sugar over `SetChordDuration` / `SetRestDuration`. See `docs/edit-commands.md`.
public struct SetDots: EditCommand {
    public let location: VoiceElementID
    public let dots: Int

    public init(at location: VoiceElementID, dots: Int) {
        self.location = location
        self.dots = dots
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The slot's current dot count, or `nil` when it has no dotted spelling or is not a chord or rest — what the
    /// planner compares against so a restating write plans to nothing.
    static func current(at location: VoiceElementID, in score: Score) -> Int? {
        guard case let .chord(chord)? = score[location] else { return nil }
        return chord.duration.baseAndDots()?.dots
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case let .chord(chord) = element else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chordOrRest))
        }
        guard (0 ... 3).contains(dots), let decomposed = chord.duration.baseAndDots() else {
            throw Self.refused(.notDottable(at: location))
        }
        let duration = decomposed.base.dotted(dots)
        return chord.notes.isEmpty
            ? try SetRestDuration(at: location, duration: duration).apply(to: &score)
            : try SetChordDuration(at: location, duration: duration).apply(to: &score)
    }
}
