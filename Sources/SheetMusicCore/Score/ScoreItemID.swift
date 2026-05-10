import Foundation

/// A selectable score item — a specific notehead (`NoteID`), a
/// rest (`RestID`), a tuplet bracket (`TupletID`), or a clef
/// (`ClefAnchor`).
///
/// Produced by hit-testing and consumed by selection APIs.
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case tuplet(TupletID)
    case clef(ClefAnchor)

    public var staff: StaffAddress {
        switch self {
        case let .note(id): return id.staff
        case let .rest(id): return id.staff
        case let .tuplet(id): return id.staff
        case let .clef(.explicit(id)): return id.staff
        case let .clef(.staffDefault(staff)): return staff
        }
    }

    public var measureIndex: Int {
        switch self {
        case let .note(id): return id.measureIndex
        case let .rest(id): return id.measureIndex
        case let .tuplet(id): return id.measureIndex
        case let .clef(.explicit(id)): return id.measureIndex
        case .clef(.staffDefault): return 0
        }
    }

    public var voiceIndex: Int {
        switch self {
        case let .note(id): return id.voiceIndex
        case let .rest(id): return id.voiceIndex
        case let .tuplet(id): return id.voiceIndex
        case let .clef(.explicit(id)): return id.voiceIndex
        case .clef(.staffDefault): return 0
        }
    }

    /// Element index of this item — for tuplets this is the
    /// `startElementIndex` (the first member). For staff-default
    /// clefs this is `0` (a positional approximation; the
    /// authoritative target is the `ClefAnchor` itself).
    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        case let .tuplet(id): return id.startElementIndex
        case let .clef(.explicit(id)): return id.elementIndex
        case .clef(.staffDefault): return 0
        }
    }
}
