import Foundation

/// A selectable score item — either a specific notehead (`NoteID`)
/// or a rest (`RestID`).
///
/// Produced by hit-testing and consumed by selection APIs.
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)

    public var staffIndex: Int {
        switch self {
        case let .note(id): return id.staffIndex
        case let .rest(id): return id.staffIndex
        }
    }

    public var measureIndex: Int {
        switch self {
        case let .note(id): return id.measureIndex
        case let .rest(id): return id.measureIndex
        }
    }

    public var voiceIndex: Int {
        switch self {
        case let .note(id): return id.voiceIndex
        case let .rest(id): return id.voiceIndex
        }
    }

    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        }
    }
}
