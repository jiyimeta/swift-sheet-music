import SheetMusicFoundation

/// A selectable score item — a specific notehead (`NoteID`), a
/// rest (`RestID`), a tuplet bracket (`TupletID`), a clef
/// (`ClefAnchor`), or one piece of engraved text (`ScoreTextID`).
///
/// Produced by hit-testing and consumed by selection APIs.
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case tuplet(TupletID)
    case clef(ClefAnchor)
    /// One engraved lyric syllable, staff / system text, chord
    /// symbol or rehearsal mark. See `ScoreTextID` for why the four
    /// text kinds nest inside one case, and for why a lyric
    /// selection is one syllable rather than a verse row.
    case text(ScoreTextID)

    public var staff: StaffAddress {
        switch self {
        case let .note(id): return id.staff
        case let .rest(id): return id.staff
        case let .tuplet(id): return id.staff
        case let .clef(.explicit(id)): return id.staff
        case let .clef(.staffDefault(staff)): return staff
        case let .text(id):
            // A rehearsal mark has no anchor: it is a system element
            // engraved once, on the score's top staff, which is the
            // address every layout / geometry consumer of this
            // accessor means by it.
            return id.anchor?.staff
                ?? StaffAddress(partIndex: 0, staffIndexInPart: 0)
        }
    }

    public var measureIndex: Int {
        switch self {
        case let .note(id): return id.measureIndex
        case let .rest(id): return id.measureIndex
        case let .tuplet(id): return id.measureIndex
        case let .clef(.explicit(id)): return id.measureIndex
        case .clef(.staffDefault): return 0
        case let .text(.rehearsalMark(measureIndex)): return measureIndex
        case let .text(id): return id.anchor?.measureIndex ?? 0
        }
    }

    public var voiceIndex: Int {
        switch self {
        case let .note(id): return id.voiceIndex
        case let .rest(id): return id.voiceIndex
        case let .tuplet(id): return id.voiceIndex
        case let .clef(.explicit(id)): return id.voiceIndex
        case .clef(.staffDefault): return 0
        case let .text(id): return id.anchor?.voiceIndex ?? 0
        }
    }

    /// Element index of this item — for tuplets this is the
    /// `startElementIndex` (the first member). For staff-default
    /// clefs this is `0` (a positional approximation; the
    /// authoritative target is the `ClefAnchor` itself), and for a
    /// rehearsal mark likewise `0` (the authoritative target is the
    /// bar index, which `measureIndex` answers exactly).
    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        case let .tuplet(id): return id.startElementIndex
        case let .clef(.explicit(id)): return id.elementIndex
        case .clef(.staffDefault): return 0
        case let .text(id): return id.anchor?.elementIndex ?? 0
        }
    }

    /// The text this item names, or `nil` when it names a notehead,
    /// rest, tuplet or clef. The one test a consumer needs to ask
    /// "is this selection a piece of engraved text".
    public var textID: ScoreTextID? {
        guard case let .text(id) = self else { return nil }
        return id
    }
}
