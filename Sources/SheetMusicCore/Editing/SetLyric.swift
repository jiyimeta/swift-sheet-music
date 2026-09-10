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
    private let destinationVerse: Int?

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
        destinationVerse = nil
    }

    private init(restoring lyrics: [Lyric], at location: VoiceElementID, verse: Int) {
        self.location = location
        self.verse = verse
        let lyric = lyrics.indices.contains(verse) ? lyrics[verse] : nil
        text = lyric?.text
        syllabic = lyric?.syllabic ?? .single
        ticks = lyric?.ticks ?? 0
        restoredLyrics = lyrics
        destinationVerse = nil
    }

    /// The verse move shares this command's padding, trimming, and exact-array inverse.
    init(moving verse: Int, to destination: Int, at location: VoiceElementID) {
        self.location = location
        self.verse = verse
        text = nil
        syllabic = .single
        ticks = 0
        restoredLyrics = nil
        destinationVerse = destination
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

        if let destinationVerse {
            guard destinationVerse >= 0 else { throw Self.refused(.invalidVerse(destinationVerse)) }
            guard chord.lyrics.indices.contains(verse), !chord.lyrics[verse].text.isEmpty else {
                throw Self.refused(.targetNotFound(location))
            }
            if destinationVerse != verse {
                if chord.lyrics.indices.contains(destinationVerse), !chord.lyrics[destinationVerse].text.isEmpty {
                    throw Self.refused(.occupiedLyricVerse(destinationVerse))
                }
                var moved = chord.lyrics[verse]
                moved.verse = destinationVerse
                Self.pad(&chord.lyrics, through: destinationVerse)
                chord.lyrics[verse] = Lyric(text: "", verse: verse)
                chord.lyrics[destinationVerse] = moved
                Self.trim(&chord.lyrics)
            }
        } else if let text {
            let trimmed = text.trimmingWhitespaceAndNewlines()
            guard !trimmed.isEmpty else {
                throw Self.refused(.emptyLyricText)
            }
            Self.pad(&chord.lyrics, through: verse)
            var lyric = chord.lyrics[verse]
            lyric.text = trimmed
            lyric.syllabic = syllabic
            lyric.ticks = ticks
            lyric.verse = verse
            chord.lyrics[verse] = lyric
        } else if chord.lyrics.indices.contains(verse) {
            chord.lyrics[verse] = Lyric(text: "", verse: verse)
            Self.trim(&chord.lyrics)
        }

        score[location] = .chord(chord)
        return SetLyric(restoring: previous, at: location, verse: verse)
    }

    private static func pad(_ lyrics: inout [Lyric], through verse: Int) {
        while lyrics.count <= verse {
            lyrics.append(Lyric(text: "", verse: lyrics.count))
        }
    }

    private static func trim(_ lyrics: inout [Lyric]) {
        while lyrics.last?.text.isEmpty == true {
            lyrics.removeLast()
        }
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
