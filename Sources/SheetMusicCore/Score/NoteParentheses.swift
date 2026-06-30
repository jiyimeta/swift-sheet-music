/// Round-parenthesis enclosure drawn around a notehead, used by MuseScore
/// for editorial / cautionary / "ghost" notes. Orthogonal to the notehead
/// shape (`Note.headType`); only round parentheses exist for noteheads
/// (square brackets are an accidental-only feature).
///
/// C++: `mu::engraving::ParenthesesMode` (`src/engraving/types/types.h`).
/// MuseScore only ever sets `both` or `none` for notes, but the full
/// directional set is modeled so a single side round-trips if encountered.
public enum NoteParentheses: Sendable, Equatable {
    case none
    case left
    case right
    case both

    /// Decode from a MuseScore `<parentheses>` text token
    /// (`none` / `left` / `right` / `both`). Unknown tokens → `.none`.
    public init(mscxToken: String) {
        switch mscxToken {
        case "left": self = .left
        case "right": self = .right
        case "both": self = .both
        default: self = .none
        }
    }

    /// MuseScore `<parentheses>` text token.
    public var mscxToken: String {
        switch self {
        case .none: "none"
        case .left: "left"
        case .right: "right"
        case .both: "both"
        }
    }

    /// True when a left parenthesis should be drawn.
    public var hasLeft: Bool {
        self == .left || self == .both
    }

    /// True when a right parenthesis should be drawn.
    public var hasRight: Bool {
        self == .right || self == .both
    }
}
