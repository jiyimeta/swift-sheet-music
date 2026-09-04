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

    /// Source XML children this model does not represent.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        subtype: String,
        velocity: Int,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.subtype = subtype
        self.velocity = velocity
        self.properties = properties
        self.preservedMarkup = preservedMarkup
        elementProperties = ElementProperties(visible: visible)
    }

    /// MuseScore's default velocity for a symbolic dynamic (`dynList`, `dynamic.cpp:54-71`): what a `<Dynamic>`
    /// without `<velocity>` plays at, and what `SetDynamic` writes for a subtype it is handed. Unknown
    /// subtypes — `sfz`, `rfz`, a typo — are `mf`.
    public static func defaultVelocity(for subtype: String) -> Int {
        switch subtype {
        case "ppppp": 5
        case "pppp": 10
        case "ppp": 16
        case "pp": 33
        case "p": 49
        case "mp": 64
        case "mf": 80
        case "f": 96
        case "ff": 112
        case "fff": 126
        case "ffff", "fffff": 127
        default: 80
        }
    }
}
