import SheetMusicFoundation

/// The four score-style flags that decide the case of a chord symbol's root and bass letters.
///
/// MuseScore draws the stored `<rootCase>` / `<bassCase>` only while *Automatic capitalization* is off; otherwise the
/// case comes from this style (`Harmony::rootRenderCase`, `dom/harmony.cpp:611-680`). Defaults are MuseScore's
/// (`style/styledef.cpp:494-497`).
public struct ChordSymbolCaseStyle: Sendable, Equatable {
    /// `Sid::automaticCapitalization`.
    public var automaticCapitalization: Bool
    /// `Sid::lowerCaseMinorChords`.
    public var lowerCaseMinorChords: Bool
    /// `Sid::lowerCaseBassNotes`.
    public var lowerCaseBassNotes: Bool
    /// `Sid::allCapsNoteNames`.
    public var allCapsNoteNames: Bool

    public init(
        automaticCapitalization: Bool = true,
        lowerCaseMinorChords: Bool = false,
        lowerCaseBassNotes: Bool = false,
        allCapsNoteNames: Bool = false,
    ) {
        self.automaticCapitalization = automaticCapitalization
        self.lowerCaseMinorChords = lowerCaseMinorChords
        self.lowerCaseBassNotes = lowerCaseBassNotes
        self.allCapsNoteNames = allCapsNoteNames
    }

    public static let museScoreDefaults = ChordSymbolCaseStyle()

    /// `Harmony::rootRenderCase` (`dom/harmony.cpp:611-656`): the stored case only while automatic capitalization is
    /// off; otherwise upper under all-caps note names, capitalized by default, and lower for a minor, diminished or
    /// half-diminished quality when `lowerCaseMinorChords` is on (that override wins over all-caps).
    package func rootCase(stored: NoteCase, suffix: String) -> NoteCase {
        guard automaticCapitalization else { return stored }
        if lowerCaseMinorChords, Self.isMinorLike(suffix: suffix) { return .lower }
        return allCapsNoteNames ? .upper : .capitalize
    }

    /// `Harmony::bassRenderCase` (`dom/harmony.cpp:658-680`).
    package func bassCase(stored: NoteCase) -> NoteCase {
        guard automaticCapitalization else { return stored }
        if lowerCaseBassNotes { return .lower }
        return allCapsNoteNames ? .upper : .capitalize
    }

    private static let majorTokens: Set = ["ma", "maj", "major", "t", "^"]
    private static let minorTokens: Set = ["mi", "min", "minor", "-", "="]
    private static let diminishedTokens: Set = ["dim", "o"]
    private static let augmentedTokens: Set = ["aug", "+"]
    private static let modifiersStartingWithQuality: Set = ["tristan", "omit", "type"]

    /// Whether a chord name's quality is minor, diminished or half-diminished, read the way `ParsedChord::parse`
    /// reads the leading token (`dom/chordlist.cpp:596-681`): the characters up to the first non-zero digit, `(` or
    /// `,`; a token that merely starts with a quality (`mima7`) is cut back to the longest quality prefix, and `madd`
    /// keeps `m`. Only the exact lower-case `m` is minor, so `M` stays major.
    package static func isMinorLike(suffix: String) -> Bool {
        var token = ""
        var tokenLower = ""
        var initial = ""
        for character in suffix {
            if "123456789(,".contains(character) { break }
            token.append(character)
            tokenLower = token.lowercased()
            if tokenLower == "m" || majorTokens.contains(tokenLower) || minorTokens.contains(tokenLower)
                || diminishedTokens.contains(tokenLower) || augmentedTokens.contains(tokenLower)
            {
                initial = token
            }
        }
        if tokenLower.hasPrefix("madd"), let first = token.first { initial = String(first) }
        if !initial.isEmpty, initial != token, !modifiersStartingWithQuality.contains(tokenLower) {
            token = initial
            tokenLower = initial.lowercased()
        }
        if token == "M" || majorTokens.contains(tokenLower) { return false }
        return token == "m" || minorTokens.contains(tokenLower) || diminishedTokens.contains(tokenLower)
            || tokenLower == "0"
    }
}
