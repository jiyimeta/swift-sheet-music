import SheetMusicFoundation

/// Write (or clear) a chord's tremolo — the buzz-roll bars on its stem, or the two-chord alternation between it
/// and its neighbour.
///
/// `nil` clears. A `.between` tremolo is refused unless the NEXT timed element of the voice is a chord: the
/// follower is named by adjacency rather than stored (`Tremolo.swift`), so writing one over a rest or at the end
/// of a bar produces a pair whose second half does not exist — the decoder drops exactly that shape on the way
/// back in. `.single` has no such requirement.
///
/// The follower carries no tremolo of its own. MuseScore writes the same `<Tremolo>` on both members and the decoder
/// strips it from the second (`MSCXDecoder+Voice.resolveTremoloPairs`), so this model's one-sided storage is the
/// canonical form and the encoder re-doubles it on the way out. What the follower does take is the pair's look:
/// making a two-note tremolo writes both chords twice as long as they last (`Chord.isWrittenDoubled`), and breaking one
/// writes them as long again, as MuseScore's `Chord::setTremoloTwoChord` doubles and restores the written type — so
/// two quarters under the tremolo draw as two halves and still fill a half.
///
/// The inverse this returns can itself be refused — `.noNextChord`, if a later edit removed the follower before
/// undo runs. `ScoreEditor.undo()` pops its stack LIFO, so whatever removed the follower was applied after this
/// command and is undone first, restoring the follower before this inverse ever resolves; nothing in this command
/// re-checks that at undo time.
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
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let followerID = NextChordProbe.nextTimedElementID(after: location, in: score)
        if tremolo?.span == .between {
            guard let followerID, case let .chord(follower)? = score[followerID], !follower.notes.isEmpty else {
                throw Self.refused(.noNextChord(at: location))
            }
        }
        let inverse = SetTremolo(at: location, tremolo: chord.tremolo)
        // Making or breaking a two-note tremolo doubles or restores both chords' written value, as MuseScore's
        // `Chord::setTremoloTwoChord` does; their lengths stay.
        let pairs = tremolo?.span == .between
        let paired = chord.tremolo?.span == .between
        chord.tremolo = tremolo
        if pairs != paired {
            chord.isWrittenDoubled = pairs
            if let followerID, case var .chord(follower)? = score[followerID], !follower.notes.isEmpty {
                follower.isWrittenDoubled = pairs
                score[followerID] = .chord(follower)
            }
        }
        score[location] = .chord(chord)
        return inverse
    }
}
