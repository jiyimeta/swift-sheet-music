import SheetMusicFoundation

/// Write (or clear) a chord's tremolo — the buzz-roll bars on its stem, or the two-chord alternation between it
/// and its neighbour.
///
/// `nil` clears. A `.between` tremolo is refused unless the NEXT timed element of the voice is a chord: the
/// follower is named by adjacency rather than stored (`Tremolo.swift`), so writing one over a rest or at the end
/// of a bar produces a pair whose second half does not exist — the decoder drops exactly that shape on the way
/// back in. `.single` has no such requirement.
///
/// The follower is not modified. MuseScore writes the same `<Tremolo>` on both members and the decoder strips it
/// from the second (`MSCXDecoder+Voice.resolveTremoloPairs`), so this model's one-sided storage is the canonical
/// form and the encoder re-doubles it on the way out.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. See `docs/edit-commands.md`.
public struct SetTremolo: EditCommand {
    public let location: VoiceElementID
    public let tremolo: Tremolo?

    public init(at location: VoiceElementID, tremolo: Tremolo?) {
        self.location = location
        self.tremolo = tremolo
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The chord's tremolo, or `nil` both when there is none and when `location` names no chord. The planner
    /// distinguishes those two by asking `score[location]` itself; a restating write plans to nothing either way,
    /// and a missing target is the command's `.targetNotFound` to raise.
    static func current(at location: VoiceElementID, in score: Score) -> Tremolo? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return chord.tremolo
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        if tremolo?.span == .between {
            guard case let .chord(follower)? = NextChordProbe.nextTimedElement(after: location, in: score),
                  !follower.notes.isEmpty
            else {
                throw Self.refused(.noNextChord(at: location))
            }
        }
        let inverse = SetTremolo(at: location, tremolo: chord.tremolo)
        chord.tremolo = tremolo
        score[location] = .chord(chord)
        return inverse
    }
}
