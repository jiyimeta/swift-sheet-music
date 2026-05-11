import Foundation

/// Replaces the lyrics array on a chord. Inverse is another
/// `SetLyrics` carrying the prior lyrics.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` —
/// > read the chord, swap its `lyrics`, write it back. It exists
/// > to give the operation a domain-meaningful name; callers can
/// > equally construct an equivalent `ReplaceVoiceElement`
/// > directly. See `docs/edit-commands.md` for the policy.
///
/// Single-verse callers pass `[Lyric(text: "syllable")]`; multi-verse
/// callers pass one entry per verse, in order. Pass `[]` to clear.
public struct SetLyrics: EditCommand {
    public let location: VoiceElementID
    public let lyrics: [Lyric]

    public init(at location: VoiceElementID, lyrics: [Lyric]) {
        self.location = location
        self.lyrics = lyrics
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard case var .chord(chord) = score[location],
              !chord.notes.isEmpty
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetLyrics: element at \(location) "
                    + "is not a chord (rests can't carry lyrics)",
            )
        }
        let prior = chord.lyrics
        chord.lyrics = lyrics
        score[location] = .chord(chord)
        return SetLyrics(at: location, lyrics: prior)
    }
}
