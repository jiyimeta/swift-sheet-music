import SheetMusicFoundation

/// One `SetLyric` reduced to its scalars, so a batch of them can travel as an `EditIntent` payload and across the
/// Android wire without carrying model metadata.
///
/// `SetLyric` already takes scalars for exactly this reason. What this type adds is the plural: one lyric keystroke
/// plans up to three writes — a repair to the preceding syllable, the syllable being typed, and a repair to the
/// destination — and they have to land as ONE undo step, so the intent carries the list rather than the caller
/// issuing three intents. The repairs are what MuseScore's `NotationInteraction::navigateToNextSyllable` does to the
/// neighbors of the syllable being entered; see `LyricInputPlanner`, which decides them.
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

    /// The one edit `writes` stands for, as a single undo step, or `nil` for an empty list.
    ///
    /// THE only place a list of writes becomes a command. `LyricInputPlanner.Plan.command` and
    /// `ScoreEditSession`'s `.setLyricSyllables` planner both call it, which is what makes "the plan's command and
    /// the intent's command are the same edit" a fact about the code rather than about two call sites happening to
    /// agree. They did not agree before: the planner anchored the composite on the caret while the intent planner
    /// anchored it on the first write, and those differ for a deletion that repairs both neighbors.
    ///
    /// **The anchor is the first write.** `CompositeEditCommand.location` is what a host scrolls into view, and a
    /// list of writes is all this function is given — no caret travels with an `EditIntent`, so a rule naming the
    /// caret would not be computable here. Taking the first member is the rule `ScoreEditSession`'s own
    /// `.composite` planner already applies (`location: first.affectedLocation`), so the two composites built from
    /// a list in this module are built the same way.
    ///
    /// That rule lands on the caret for every keystroke `LyricInputPlanner` plans, because the planner emits the
    /// syllable the caret is on FIRST and the neighbor repairs after it — see `plan(typing:terminatedBy:at:in:)`.
    /// A single write comes back as a bare `SetLyric` rather than a one-member composite, so the overwhelmingly
    /// common keystroke is unchanged down to the command it produces.
    static func command(for writes: [LyricSyllableWrite]) -> (any EditCommand)? {
        let commands = writes.map(\.command)
        guard let first = commands.first else { return nil }
        guard commands.count > 1 else { return first }
        return CompositeEditCommand(commands: commands, location: first.location)
    }
}
