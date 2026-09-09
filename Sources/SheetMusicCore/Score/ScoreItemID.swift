import SheetMusicFoundation

/// A selectable score item — a specific notehead (`NoteID`), a
/// rest (`RestID`), a tuplet bracket (`TupletID`), a clef
/// (`ClefAnchor`), engraved text (`ScoreTextID`), or an engraved element (`ScoreElementID`).
///
/// Produced by hit-testing and consumed by selection APIs.
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case tuplet(TupletID)
    case clef(ClefAnchor)
    /// One engraved lyric syllable, staff / system text, chord
    /// symbol or rehearsal mark. See `ScoreTextID` for why the
    /// text kinds nest inside one case, and for why a lyric
    /// selection is one syllable rather than a verse row.
    case text(ScoreTextID)
    /// An engraved element addressed through its anchor or bar; see `ScoreElementID`.
    case element(ScoreElementID)

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
        case let .element(id):
            return id.anchor?.staff ?? StaffAddress(partIndex: 0, staffIndexInPart: 0)
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
        case let .element(id): return id.anchor?.measureIndex ?? id.measureIndexIfAddressedByBar ?? 0
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
        case let .element(id): return id.anchor?.voiceIndex ?? 0
        }
    }

    /// Element index of this item — for tuplets this is the
    /// `startElementIndex` (the first member). For staff-default
    /// clefs this is `0` (a positional approximation; the
    /// authoritative target is the `ClefAnchor` itself), and for a
    /// bar-addressed item likewise `0` (the authoritative target is the
    /// bar index, which `measureIndex` answers exactly). Bar-addressed elements
    /// also approximate staff with the top staff and voice with `0`.
    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        case let .tuplet(id): return id.startElementIndex
        case let .clef(.explicit(id)): return id.elementIndex
        case .clef(.staffDefault): return 0
        case let .text(id): return id.anchor?.elementIndex ?? 0
        case let .element(id): return id.anchor?.elementIndex ?? 0
        }
    }

    /// The engraved text this item names. Non-text items report `nil`.
    public var textID: ScoreTextID? {
        guard case let .text(id) = self else { return nil }
        return id
    }

    /// The engraved element this item names. Other items report `nil`.
    public var elementID: ScoreElementID? {
        guard case let .element(id) = self else { return nil }
        return id
    }
}
