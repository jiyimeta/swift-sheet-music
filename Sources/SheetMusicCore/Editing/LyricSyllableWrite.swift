import SheetMusicFoundation

/// One `SetLyric` reduced to its scalars, so a batch of them can travel as an `EditIntent` payload and across the
/// Android wire without carrying model metadata.
///
/// `SetLyric` already takes scalars for exactly this reason. What this type adds is the plural: one lyric keystroke
/// plans up to three writes — a repair to the preceding syllable, the syllable being typed, and a repair to the
/// destination — and they have to land as ONE undo step, so the intent carries the list rather than the caller
/// issuing three intents. The repairs are what MuseScore's `NotationInteraction::navigateToNextSyllable` does to the
/// neighbours of the syllable being entered; see `LyricInputPlanner`, which decides them.
public struct LyricSyllableWrite: Sendable, Equatable, Hashable {
    public let location: VoiceElementID
    public let verse: Int
    /// `nil` removes this verse's syllable.
    public let text: String?
    /// Ignored when `text` is `nil`.
    public let syllabic: Syllabic
    /// Melisma length in ticks; `0` for none. Ignored when `text` is `nil`.
    public let ticks: Int

    public init(
        location: VoiceElementID,
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
    }

    /// The command this write stands for.
    ///
    /// Every path that turns a write into an edit goes through here, so a write and the command planned from it can
    /// never describe different edits — the invariant `LyricInputPlanner.Plan` states between its `writes` and its
    /// `command`.
    var command: SetLyric {
        SetLyric(at: location, verse: verse, text: text, syllabic: syllabic, ticks: ticks)
    }
}
