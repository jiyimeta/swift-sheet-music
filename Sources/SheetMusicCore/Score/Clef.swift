import SheetMusicFoundation

/// Clef change. Display-only — does not affect MIDI output.
/// C++: `mu::engraving::Clef`.
public struct Clef: Sendable, Equatable {
    public var concertClefType: String
    public var transposingClefType: String?

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
        concertClefType: String,
        transposingClefType: String? = nil,
        visible: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.concertClefType = concertClefType
        self.transposingClefType = transposingClefType
        self.preservedMarkup = preservedMarkup
        elementProperties = ElementProperties(visible: visible)
    }
}
