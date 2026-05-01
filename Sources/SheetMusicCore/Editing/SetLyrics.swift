import Foundation

/// Replaces the lyrics array on a chord. Inverse is another
/// `SetLyrics` carrying the prior lyrics.
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

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard case var .chord(chord) = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetLyrics: element at \(location) is not a chord")
        }
        let prior = chord.lyrics
        chord.lyrics = lyrics
        score[location] = .chord(chord)
        return SetLyrics(at: location, lyrics: prior)
    }
}
