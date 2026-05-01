import Foundation

/// A selectable score item — a specific notehead (`NoteID`), a
/// rest (`RestID`), or a tuplet bracket (`TupletID`).
///
/// Produced by hit-testing and consumed by selection APIs.
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case tuplet(TupletID)

    public var staffIndex: Int {
        switch self {
        case let .note(id): return id.staffIndex
        case let .rest(id): return id.staffIndex
        case let .tuplet(id): return id.staffIndex
        }
    }

    public var measureIndex: Int {
        switch self {
        case let .note(id): return id.measureIndex
        case let .rest(id): return id.measureIndex
        case let .tuplet(id): return id.measureIndex
        }
    }

    public var voiceIndex: Int {
        switch self {
        case let .note(id): return id.voiceIndex
        case let .rest(id): return id.voiceIndex
        case let .tuplet(id): return id.voiceIndex
        }
    }

    /// Element index of this item — for tuplets this is the
    /// `startElementIndex` (the first member). Useful for sort /
    /// position comparisons.
    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        case let .tuplet(id): return id.startElementIndex
        }
    }
}
