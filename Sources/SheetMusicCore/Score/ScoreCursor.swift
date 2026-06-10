/// Where a playback cursor is currently parked.
///
/// MuseScore's cursor advances on two kinds of column:
///
/// * Every chord / rest onset (`.item`) — the actual notated event
///   the user clicked or that just sounded.
/// * Every metric beat derived from the time signature's denominator
///   (`.beat`) — quarter steps in 3/4 or 4/4, eighth steps in 6/8 or
///   12/8, etc. These exist between chord onsets so a held half note
///   in 4/4 still gets a cursor "tick" on beat 2.
///
/// The visual cursor X for `.item` comes from the chord / rest
/// column itself; for `.beat` it's interpolated linearly between
/// the surrounding chord / rest columns.
public enum ScoreCursor: Hashable, Sendable {
    case item(ScoreItemID)
    case beat(measureIndex: Int, tickInMeasure: Int)
}

extension ScoreCursor {
    /// The measure this cursor points at. Both cases carry this directly: `.beat` stores it as a labeled field;
    /// `.item` derives it from `ScoreItemID.measureIndex`.
    public var measureIndex: Int {
        switch self {
        case let .beat(measureIndex, _): measureIndex
        case let .item(id): id.measureIndex
        }
    }
}
