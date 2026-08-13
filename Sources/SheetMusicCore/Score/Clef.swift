import SheetMusicFoundation

/// Clef change. Display-only — does not affect MIDI output.
/// C++: `mu::engraving::Clef`.
public struct Clef: Sendable, Equatable {
    public var concertClefType: String
    public var transposingClefType: String?

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(concertClefType: String, transposingClefType: String? = nil, visible: Bool = true) {
        self.concertClefType = concertClefType
        self.transposingClefType = transposingClefType
        elementProperties = ElementProperties(visible: visible)
    }
}
