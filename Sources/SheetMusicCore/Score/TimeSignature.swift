import Foundation

/// A time signature like 4/4 or 6/8. C++: `mu::engraving::TimeSig`.
public struct TimeSignature: Sendable, Equatable {
    public var numerator: Int
    public var denominator: Int

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(numerator: Int, denominator: Int, visible: Bool = true) {
        self.numerator = numerator
        self.denominator = denominator
        elementProperties = ElementProperties(visible: visible)
    }
}
