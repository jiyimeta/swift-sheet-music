import SheetMusicFoundation

/// How one tuplet's marking is drawn: which side it sits on, what its number says, whether it has a bracket, and
/// whether it shows at all. None of it changes what sounds — the members' durations already carry the ratio.
///
/// The three styled settings are MuseScore's per-tuplet overrides of the score style (`Pid::DIRECTION`,
/// `Pid::NUMBER_TYPE`, `Pid::BRACKET_TYPE`). MuseScore writes one only when it differs from the style
/// (`TWrite::writeProperty` skips a styled property), so `nil` means "the file said nothing; follow the score's
/// style", and a set value is written back even when it happens to equal MuseScore's built-in default. Layout
/// reads an unset value as MuseScore's default style (`auto` / `number` / `auto`): the score's own
/// `<tupletDirection>`, `<tupletNumberType>` and `<tupletBracketType>` survive a save in
/// `ScoreStyle.preservedMarkup` but are not read yet.
/// C++: the `tupletStyle` properties of `mu::engraving::Tuplet` (`dom/tuplet.cpp`).
public struct TupletAppearance: Sendable, Equatable {
    /// Which side of the notes the number and bracket go. C++: `DirectionV`; MSCX `<direction>` as `auto` / `up` /
    /// `down`.
    public enum Direction: Sendable, Equatable, CaseIterable {
        /// The side the members' stems point to — MuseScore's `TupletLayout::computeDirection`.
        case auto
        case up
        case down
    }

    /// What the marking's number says. C++: `TupletNumberType`; MSCX `<numberType>` as its ordinal.
    public enum NumberType: Int, Sendable, Equatable, CaseIterable {
        /// The actual-note count alone — "3".
        case number = 0
        /// Actual to normal — "3:2".
        case ratio = 1
        /// No number (`NO_TEXT`). A bracket, if drawn, runs unbroken. Not `none`, which an optional would read as nil.
        case noText = 2
    }

    /// Whether the marking has a bracket. C++: `TupletBracketType`; MSCX `<bracketType>` as its ordinal.
    public enum BracketType: Int, Sendable, Equatable, CaseIterable {
        /// A bracket unless one beam already joins the first and last members — `Tuplet::calcHasBracket`.
        case auto = 0
        case bracket = 1
        /// No bracket (`SHOW_NO_BRACKET`). Not `none`, which an optional would read as nil.
        case noBracket = 2
    }

    public var direction: Direction?
    public var numberType: NumberType?
    public var bracketType: BracketType?

    /// Base element properties shared with every engravable element. Carries `<visible>`, `<color>`, `<offset>`;
    /// see `ElementProperties`.
    public var elementProperties: ElementProperties

    /// Sugar over `elementProperties.visible`. A hidden tuplet draws neither number nor bracket.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source `<Tuplet>` children this model does not represent — the user-dragged bracket ends (`<p1>`, `<p2>`),
    /// bracket width and font overrides, part-linking tags. See `PreservedXML`.
    public var preservedMarkup: [PreservedXML]

    public init(
        direction: Direction? = nil,
        numberType: NumberType? = nil,
        bracketType: BracketType? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.direction = direction
        self.numberType = numberType
        self.bracketType = bracketType
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }

    /// The text the marking's number shows for `actualNotes` in the time of `normalNotes` — `""` when it shows none.
    /// An unset `numberType` is MuseScore's default style, the bare count. C++: `TupletLayout::createNumber`.
    public func numberText(actualNotes: Int, normalNotes: Int) -> String {
        switch numberType ?? .number {
        case .number: "\(actualNotes)"
        case .ratio: "\(actualNotes):\(normalNotes)"
        case .noText: ""
        }
    }
}
