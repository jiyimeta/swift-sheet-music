import Foundation

/// Where a syllable sits inside a hyphenated word. Mirrors
/// MuseScore's `<syllabic>` mscx element.
///
/// - `.single`: stand-alone word (or no syllabic info).
/// - `.begin`: first syllable of a word; a hyphen is drawn between
///   this and the next syllable.
/// - `.middle`: a middle syllable; hyphens on both sides.
/// - `.end`: last syllable; hyphen only to the left.
public enum Syllabic: Sendable, Equatable {
    case single
    case begin
    case middle
    case end

    /// Parse the value of an mscx `<syllabic>` element. Returns nil
    /// for unknown values so the caller can fall back to `.single`.
    public init?(mscxValue: String) {
        switch mscxValue {
        case "single": self = .single
        case "begin": self = .begin
        case "middle": self = .middle
        case "end": self = .end
        default: return nil
        }
    }
}

/// One lyric syllable attached to a `Chord` (for a single verse).
///
/// C++: `mu::engraving::Lyrics` (subset). The combination of
/// `syllabic` and `ticks` drives melisma rendering: a syllable with
/// `ticks` greater than its anchor chord's duration is held across
/// the following notes and is drawn with an underscore-style
/// horizontal line.
public struct Lyric: Sendable, Equatable {
    public var text: String
    public var syllabic: Syllabic
    /// Duration of the syllable in MIDI ticks at the score's
    /// division. A value greater than the anchor chord's duration
    /// turns the syllable into a melisma.
    public var ticks: Int
    /// Verse number (0-indexed). Even verses (0, 2, …) inherit from
    /// `TextStyleType.lyricsOdd`; odd indices (1, 3, …) from
    /// `lyricsEven`. MuseScore numbers them the same way internally.
    public var verse: Int
    /// Per-element font overrides. `nil`-fields inherit from
    /// `lyricsOdd` / `lyricsEven` (both Edwin 10 pt by default).
    public var properties: TextProperties

    public init(
        text: String,
        syllabic: Syllabic = .single,
        ticks: Int = 0,
        verse: Int = 0,
        properties: TextProperties = TextProperties(),
    ) {
        self.text = text
        self.syllabic = syllabic
        self.ticks = ticks
        self.verse = verse
        self.properties = properties
    }

    /// Style row this lyric inherits from, picked by verse parity.
    public var styleType: TextStyleType {
        verse.isMultiple(of: 2) ? .lyricsOdd : .lyricsEven
    }
}
