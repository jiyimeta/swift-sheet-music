import SheetMusicFoundation

/// Bar line marker. Display-only — does not affect MIDI output.
/// C++: `mu::engraving::BarLine`.
public struct BarLine: Sendable, Equatable {
    public var subtype: String? // e.g. "end", "double", "start-repeat"

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
        subtype: String? = nil,
        visible: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.subtype = subtype
        self.preservedMarkup = preservedMarkup
        elementProperties = ElementProperties(visible: visible)
    }
}
