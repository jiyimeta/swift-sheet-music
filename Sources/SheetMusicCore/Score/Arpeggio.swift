import SheetMusicFoundation

/// Arpeggio attached to a chord. Spreads the chord's notes in time.
/// C++: `mu::engraving::Arpeggio`.
public struct Arpeggio: Sendable, Equatable {
    /// Mscx subtype: 0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET.
    public var subtype: Int
    /// `<timeStretch>` multiplier on the per-note offset. Defaults to 1.
    public var timeStretch: Double
    /// `<userLen1>` (currently unused by the renderer; mirrors the C++ field).
    public var userLen1: Double

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        subtype: Int,
        timeStretch: Double = 1.0,
        userLen1: Double = 0.0,
        visible: Bool = true,
    ) {
        self.subtype = subtype
        self.timeStretch = timeStretch
        self.userLen1 = userLen1
        elementProperties = ElementProperties(visible: visible)
    }

    /// True for ascending arpeggios (lowest note first); false for DOWN/DOWN_STRAIGHT.
    public var isAscending: Bool {
        subtype != 2 && subtype != 4
    }
}
