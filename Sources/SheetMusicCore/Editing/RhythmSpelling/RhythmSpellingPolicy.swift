/// The knobs that decide how `RhythmSpelling` re-spells a duration. Three questions, each with a small closed set of
/// answers, so a host can offer them as settings and persist them as raw integers.
public struct RhythmSpellingPolicy: Sendable, Hashable {
    /// The most augmentation dots a NOTE may carry. Rests are capped at one dot whatever this says: a rest with two
    /// dots is rare enough in engraved music that the dot-cap is `min(dotLevel, .single)`.
    public enum DotLevel: Int, Sendable, CaseIterable {
        case none = 0, single = 1, double = 2, triple = 3
    }

    /// How a span may cross a point where a stricter reading of the meter would split it.
    ///
    /// The splitter itself knows only "on" (`.allow`) and "off" (`.split`, `.keepWritten`): `.keepWritten` is a
    /// SPAN-level rule — it keeps the spelling the score already has — and is applied by the caller before the
    /// splitter runs. Inside `RhythmSpelling.durations` it reads as `.split`.
    public enum Crossing: Int, Sendable, CaseIterable {
        case split = 0, keepWritten = 1, allow = 2
    }

    public var dotLevel: DotLevel

    /// Whether a note may cross the middle of the bar when both ends sit on beats, or when one end touches a
    /// stressed beat (MuseScore's behavior), instead of having to start on a beat AND touch a stressed one.
    public var midBarSyncopations: Crossing

    /// Whether a rest may cross an unstressed beat when it is a single undotted value that a note would be allowed
    /// to keep there.
    public var beatCrossingRests: Crossing

    public init(
        dotLevel: DotLevel = .double,
        midBarSyncopations: Crossing = .split,
        beatCrossingRests: Crossing = .keepWritten,
    ) {
        self.dotLevel = dotLevel
        self.midBarSyncopations = midBarSyncopations
        self.beatCrossingRests = beatCrossingRests
    }

    /// folino's own taste: up to two dots, syncopations split at the middle of the bar, written beat-crossing rests
    /// kept.
    public static let `default` = RhythmSpellingPolicy(
        dotLevel: .double, midBarSyncopations: .split, beatCrossingRests: .keepWritten,
    )

    /// What MuseScore's own "regroup rhythms" produces.
    public static let museScore = RhythmSpellingPolicy(
        dotLevel: .single, midBarSyncopations: .allow, beatCrossingRests: .split,
    )
}
