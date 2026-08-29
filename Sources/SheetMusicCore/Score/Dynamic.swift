import SheetMusicFoundation

/// Dynamic marking (pp, p, mp, mf, f, ff, …). Drives MIDI velocity for following notes.
/// C++: `mu::engraving::Dynamic`.
public struct Dynamic: Sendable, Equatable {
    public var subtype: String // "p", "f", "mf", "fff", etc.
    public var velocity: Int // MIDI velocity 1..127
    /// Per-element font overrides. `nil`-fields inherit from
    /// `TextStyleType.dynamics` (Edwin 10 pt italic by default).
    public var properties: TextProperties
    /// Base element properties shared with every engravable element.
    /// Carries `<visible>` and `<color>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        subtype: String,
        velocity: Int,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
    ) {
        self.subtype = subtype
        self.velocity = velocity
        self.properties = properties
        elementProperties = ElementProperties(visible: visible)
    }
}
