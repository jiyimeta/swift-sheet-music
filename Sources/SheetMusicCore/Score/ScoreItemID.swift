import SheetMusicFoundation

/// A selectable score item — a specific notehead (`NoteID`), a
/// rest (`RestID`), a tuplet bracket (`TupletID`), a clef
/// (`ClefAnchor`), engraved text (`ScoreTextID`), an engraved element (`ScoreElementID`), or one grace note
/// (`GraceNoteID`).
///
/// Produced by hit-testing and consumed by selection APIs. Cases are appended, never reordered: the declaration
/// order is `ScoreItemIDWire`'s choice numbering.
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
    /// An engraved element addressed through its anchor, bar, or staff-owned list; see `ScoreElementID`.
    case element(ScoreElementID)
    /// One note of a grace chord. The positional accessors below answer from the owning chord's slot, so a grace
    /// selection sits on its parent's staff, bar, voice and element for every consumer that only asks those.
    case graceNote(GraceNoteID)

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
            return id.staffIfAddressed ?? id.anchor?.staff ?? StaffAddress(partIndex: 0, staffIndexInPart: 0)
        case let .graceNote(id): return id.staff
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
        case let .element(.jump(_, measureIndex, _)), let .element(.marker(_, measureIndex, _)): return measureIndex
        case let .element(id): return id.anchor?.measureIndex ?? id.measureIndexIfAddressedByBar ?? 0
        case let .graceNote(id): return id.measureIndex
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
        case let .graceNote(id): return id.voiceIndex
        }
    }

    /// Element index of this item — for tuplets this is the
    /// `startElementIndex` (the first member). For staff-default
    /// clefs this is `0` (a positional approximation; the
    /// authoritative target is the `ClefAnchor` itself), and for a
    /// bar-addressed item likewise `0` (the authoritative target is the
    /// bar index, which `measureIndex` answers exactly). A barline also
    /// approximates staff with the top staff; a key or time signature carries
    /// the staff of its selected glyph. Both approximate voice with `0`.
    /// Navigation identities retain their actual staff and measure, but approximate voice and element
    /// with `0`: their list index is not a voice slot.
    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        case let .tuplet(id): return id.startElementIndex
        case let .clef(.explicit(id)): return id.elementIndex
        case .clef(.staffDefault): return 0
        case let .text(id): return id.anchor?.elementIndex ?? 0
        case let .element(id): return id.anchor?.elementIndex ?? 0
        case let .graceNote(id): return id.elementIndex
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

    /// The grace note this item names. Other items report `nil`.
    public var graceNoteID: GraceNoteID? {
        guard case let .graceNote(id) = self else { return nil }
        return id
    }
}
