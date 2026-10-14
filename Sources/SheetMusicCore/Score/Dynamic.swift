import SheetMusicFoundation

/// Dynamic marking (pp, p, mp, mf, f, ff, sf, fp, …) and what it does to playback (`playbackRole`).
/// C++: `mu::engraving::Dynamic`.
public struct Dynamic: Sendable, Equatable {
    /// MuseScore's `DynamicSpeed`, `<veloChangeSpeed>`: how fast a two-level dynamic (fp, sfp, …) reaches its second
    /// level (`velocityChangeTicks`). Raw values are the MSCX tokens (`DYNAMIC_SPEEDS`,
    /// `engraving/types/typesconv.cpp:1588-1592`).
    public enum VelocityChangeSpeed: String, Sendable {
        case normal
        case slow
        case fast
    }

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

    /// The dynamic's own text, as plain text — "subito p", or "più " for "più <sym>dynamicForte</sym>" (a symbol is no
    /// character). `nil` while it prints its subtype's glyphs, as every dynamic made in code or by `SetDynamic` without
    /// a text does: MuseScore writes `<text>` only when it differs from the subtype's (`Dynamic::hasCustomText`,
    /// `engraving/dom/dynamic.h:98`).
    public var text: String?
    /// The `<text>` markup as read, written back verbatim while it still describes `text` (`richText`).
    public var preservedTextMarkup: PreservedTextMarkup?
    /// MuseScore `<play>`: `false` keeps the dynamic on the page and out of playback (`playbackRole`).
    public var playsBack: Bool
    /// MuseScore `<veloChangeSpeed>`.
    public var velocityChangeSpeed: VelocityChangeSpeed

    /// Source XML children this model does not represent.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        subtype: String,
        velocity: Int,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
        preservedMarkup: [PreservedXML] = [],
        text: String? = nil,
        preservedTextMarkup: PreservedTextMarkup? = nil,
        playsBack: Bool = true,
        velocityChangeSpeed: VelocityChangeSpeed = .normal,
    ) {
        self.subtype = subtype
        self.velocity = velocity
        self.properties = properties
        self.preservedMarkup = preservedMarkup
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.playsBack = playsBack
        self.velocityChangeSpeed = velocityChangeSpeed
        elementProperties = ElementProperties(visible: visible)
    }

    /// What the dynamic prints when it is not its subtype's glyphs: its formatted text while the markup is current
    /// (`richText`), else its words; `nil` while it prints its subtype (`text == nil`).
    public var displayedRichText: RichText? {
        guard let text else { return nil }
        return richText ?? RichText(plainText: text)
    }

    /// The dynamic's own text as MuseScore xml text — what `<text>` holds and a copy of it carries: the markup while it
    /// is current, else the words escaped; `nil` while the dynamic prints its subtype.
    public var customXMLText: String? {
        guard let text else { return nil }
        if let markup = preservedTextMarkup, markup.derivedText == text {
            return markup.xmlText
        }
        return PreservedTextMarkup.escapedXMLText(text)
    }

    /// MuseScore's velocity for a dynamic of `subtype` (`Dynamic::DYN_LIST`, `engraving/dom/dynamic.cpp:50-100`): the
    /// `<velocity>` it is stored and saved with — what a `<Dynamic>` without `<velocity>` reads as, and what
    /// `SetDynamic` writes. What it *plays* is `playbackRole`'s. `other-dynamics` (MuseScore's -1, no velocity) and a
    /// token MuseScore does not know are mf.
    public static func defaultVelocity(for subtype: String) -> Int {
        switch subtype {
        case "pppppp": 1
        case "ppppp": 5
        case "pppp": 10
        case "ppp": 16
        case "pp": 33
        case "p", "pf", "n": 49
        case "mp": 64
        case "f", "fp", "m": 96
        case "ff", "sf", "sfz", "sfp", "sfpp", "rfz", "rf", "fz", "r", "s": 112
        case "fff", "sff", "sffz": 126
        case "ffff", "fffff", "ffffff", "sfff", "sfffz": 127
        default: 80 // mf, z, other-dynamics, unknown
        }
    }
}
