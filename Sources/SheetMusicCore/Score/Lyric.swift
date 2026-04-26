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
        case "begin":  self = .begin
        case "middle": self = .middle
        case "end":    self = .end
        default:       return nil
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

    public init(
        text: String,
        syllabic: Syllabic = .single,
        ticks: Int = 0
    ) {
        self.text = text
        self.syllabic = syllabic
        self.ticks = ticks
    }
}
