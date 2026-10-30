/// The knobs that decide how `RhythmSpelling` re-spells a duration. Three questions, each with a small closed set of
/// answers, so a host can offer them as settings and persist them as raw integers.
public struct RhythmSpellingPolicy: Sendable, Hashable {
    /// The most augmentation dots a NOTE may carry. Rests take none where the beat is an undotted value (4/4, 2/2,
    /// 3/8) and at most one, `min(dotLevel, .single)`, where units group in threes and the beat is dotted (6/8, the
    /// group of three in 5/8), whatever this says; MuseScore's reading (`readsLikeMuseScore`) caps them at one in every
    /// meter.
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

    /// Whether the meter is read as MuseScore reads it where folino's reading differs and no knob of its own covers
    /// the difference: dotted rests where the beat is undotted, and syncopations on the 16th grid across a weaker beat.
    /// `.allow` on `midBarSyncopations` is MuseScore's setting, which no folino control writes, so it stands for the
    /// whole convention — the edit wire carries the three knobs and nothing else, and a `.museScore` intent must replay
    /// as MuseScore.
    var readsLikeMuseScore: Bool {
        midBarSyncopations == .allow
    }
}
