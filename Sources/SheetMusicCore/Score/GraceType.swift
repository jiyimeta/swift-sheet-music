import SheetMusicFoundation

/// Grace-note category. Subset of MuseScore's `NoteType` (the
/// non-grace cases — `NORMAL`, `INVALID` — are out of scope here).
/// C++: `mu::engraving::NoteType` (`engraving/dom/note.h`).
public enum GraceType: Sendable, Equatable, CaseIterable {
    case acciaccatura
    case appoggiatura
    case grace4
    case grace16
    case grace32
    case grace8after
    case grace16after
    case grace32after

    /// True for after-grace types (`grace8after` / `grace16after` /
    /// `grace32after`). MuseScore writes these *after* the parent
    /// chord in the mscx stream; we attach them to the most recent
    /// chord seen in the voice.
    public var isAfter: Bool {
        switch self {
        case .grace8after, .grace16after, .grace32after: true
        default: false
        }
    }

    /// MSCX child-tag spelling. The decoder maps `<acciaccatura/>`
    /// → `.acciaccatura`, etc. Stable across MuseScore 3 / 4.
    public var mscxTag: String {
        switch self {
        case .acciaccatura: "acciaccatura"
        case .appoggiatura: "appoggiatura"
        case .grace4: "grace4"
        case .grace16: "grace16"
        case .grace32: "grace32"
        case .grace8after: "grace8after"
        case .grace16after: "grace16after"
        case .grace32after: "grace32after"
        }
    }

    /// Reverse of `mscxTag`. Returns `nil` for any non-grace tag.
    public init?(mscxTag: String) {
        guard let match = Self.allCases.first(where: { $0.mscxTag == mscxTag })
        else { return nil }
        self = match
    }
}
