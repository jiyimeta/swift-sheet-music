import SheetMusicFoundation

/// A time signature like 4/4 or 6/8. C++: `mu::engraving::TimeSig`.
public struct TimeSignature: Sendable, Equatable {
    public var numerator: Int
    public var denominator: Int

    /// Whether this meter is drawn as its two numbers or as a symbol standing in for them (C, cut C, …).
    /// MuseScore `<subtype>` / `TimeSigType`. Purely how it LOOKS: `numerator` and `denominator` still say
    /// how long the bar is, so nothing outside layout reads this.
    public var symbol: TimeSignatureSymbol

    /// MuseScore `<showCourtesySig>` — whether the end-of-system courtesy for this signature is drawn.
    /// Layout reads it, nothing else does.
    public var showCourtesy: Bool

    /// Base element properties shared with every engravable element.
    /// Carries `<visible>` and `<color>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        numerator: Int,
        denominator: Int,
        symbol: TimeSignatureSymbol = .numeric,
        visible: Bool = true,
        showCourtesy: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.numerator = numerator
        self.denominator = denominator
        self.symbol = symbol
        self.showCourtesy = showCourtesy
        self.preservedMarkup = preservedMarkup
        elementProperties = ElementProperties(visible: visible)
    }
}
