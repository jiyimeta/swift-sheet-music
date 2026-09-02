import SheetMusicFoundation

/// A time signature like 4/4 or 6/8. C++: `mu::engraving::TimeSig`.
public struct TimeSignature: Sendable, Equatable {
    public var numerator: Int
    public var denominator: Int

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

    public init(numerator: Int, denominator: Int, visible: Bool = true, showCourtesy: Bool = true) {
        self.numerator = numerator
        self.denominator = denominator
        self.showCourtesy = showCourtesy
        elementProperties = ElementProperties(visible: visible)
    }
}
