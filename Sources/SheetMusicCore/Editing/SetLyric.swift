import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes one verse's lyric syllable on a chord.
///
/// `Chord.lyrics` is indexed by verse: the entry at index `i` has `verse == i`. This command owns that invariant
/// because layout places lyric rows by the array index it gets from `enumerated()`, not by `Lyric.verse`. Writing a
/// higher verse pads every missing lower index with an empty lyric; removal keeps interior padding but trims empty
/// entries from the end.
///
/// A write changes only the trimmed text, `syllabic`, `ticks` and normalized `verse`; it preserves the existing
/// lyric's `properties`, `elementProperties` and `preservedMarkup`. The inputs are scalar so a future `EditIntent`
/// can wrap this command without needing to carry non-wire model metadata.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` —
/// > read the chord, swap its `lyrics`, write it back. It exists
/// > to give the operation a domain-meaningful name; callers can
/// > equally construct an equivalent `ReplaceVoiceElement`
/// > directly. See `docs/edit-commands.md` for the policy.
public struct SetLyric: EditCommand {
    public let location: VoiceElementID
    public let verse: Int
    /// The syllable text; `nil` removes this verse's syllable.
    public let text: String?
    /// Ignored when `text` is `nil`.
    public let syllabic: Syllabic
    /// Melisma length in ticks; `0` for none. Ignored when `text` is `nil`.
    public let ticks: Int
    private let restoredLyrics: [Lyric]?

    public init(
        at location: VoiceElementID,
        verse: Int,
        text: String?,
        syllabic: Syllabic = .single,
        ticks: Int = 0,
    ) {
        self.location = location
        self.verse = verse
        self.text = text
        self.syllabic = syllabic
        self.ticks = ticks
        restoredLyrics = nil
    }

    private init(restoring lyrics: [Lyric], at location: VoiceElementID, verse: Int) {
        self.location = location
        self.verse = verse
        let lyric = lyrics.indices.contains(verse) ? lyrics[verse] : nil
        text = lyric?.text
        syllabic = lyric?.syllabic ?? .single
        ticks = lyric?.ticks ?? 0
        restoredLyrics = lyrics
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let previous = chord.lyrics
        if let restoredLyrics {
            chord.lyrics = restoredLyrics
            score[location] = .chord(chord)
            return SetLyric(restoring: previous, at: location, verse: verse)
        }
        guard verse >= 0 else {
            throw Self.refused(.invalidVerse(verse))
        }

        if let text {
            let trimmed = text.trimmingWhitespaceAndNewlines()
            guard !trimmed.isEmpty else {
                throw Self.refused(.emptyLyricText)
            }
            while chord.lyrics.count <= verse {
                chord.lyrics.append(Lyric(text: "", verse: chord.lyrics.count))
            }
            var lyric = chord.lyrics[verse]
            lyric.text = trimmed
            lyric.syllabic = syllabic
            lyric.ticks = ticks
            lyric.verse = verse
            chord.lyrics[verse] = lyric
        } else if chord.lyrics.indices.contains(verse) {
            chord.lyrics[verse] = Lyric(text: "", verse: verse)
            while chord.lyrics.last?.text.isEmpty == true {
                chord.lyrics.removeLast()
            }
        }

        score[location] = .chord(chord)
        return SetLyric(restoring: previous, at: location, verse: verse)
    }

    /// The lyric array entry at `verse`, including an empty padding entry, or `nil` when none exists.
    static func current(at location: VoiceElementID, verse: Int, in score: Score) -> Lyric? {
        guard verse >= 0,
              case let .chord(chord) = score[location],
              !chord.notes.isEmpty,
              chord.lyrics.indices.contains(verse)
        else { return nil }
        return chord.lyrics[verse]
    }
}
