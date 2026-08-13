import SheetMusicFoundation

/// Bracket / brace style. Mirrors MuseScore's
/// `engraving/dom/bracket.h` `BracketType` enum, including the same
/// raw integer values used in MSCX serialization.
public enum BracketType: Int, Sendable, Equatable, Codable {
    case normal = 0 // thick angle bracket — section grouping
    case brace = 1 // curly brace — multi-staff parts
    case square = 2 // thin angle bracket — same-instrument grouping
    case line = 3 // plain vertical line, no serifs
    case noBracket = -1
}

/// One bracket / brace anchored on a `Staff`. The bracket spans
/// `span` staves downward starting from this staff (counting this
/// staff as 1). `column` controls horizontal nesting: 0 sits closest
/// to the staff; higher values stack further left. Multiple bracket
/// items may share a staff.
///
/// C++: `mu::engraving::BracketItem`.
public struct BracketItem: Sendable, Equatable, Codable {
    public var type: BracketType
    public var span: Int
    public var column: Int
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` attribute flag. When false the
    /// bracket is hidden from rendered/printed output. Sugar over
    /// `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        type: BracketType,
        span: Int,
        column: Int = 0,
        visible: Bool = true,
    ) {
        self.type = type
        self.span = max(span, 1)
        self.column = max(column, 0)
        elementProperties = ElementProperties(visible: visible)
    }
}
