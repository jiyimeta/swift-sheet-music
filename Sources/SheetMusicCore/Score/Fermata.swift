import SheetMusicFoundation

/// A fermata symbol held above/below a chord or rest.
/// C++: `mu::engraving::Fermata`.
public struct Fermata: Sendable, Equatable {
    /// MuseScore `<subtype>` text (e.g. `fermataAbove`, `fermataBelow`,
    /// `fermataLongAbove`, …). Kept as a raw string because the full
    /// SMuFL-derived set is large and MuseScore 5.x extends it freely.
    public var subtype: String

    /// MIDI hold ratio. 1.0 = no stretch. MSCX `<timeStretch>` overrides
    /// the subtype default when present.
    /// C++: `mu::engraving::Fermata::timeStretch`.
    public var timeStretch: Double

    /// Base element properties shared with every engravable element.
    /// Carries `<visible>` and `<color>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(subtype: String, timeStretch: Double? = nil, visible: Bool = true) {
        self.subtype = subtype
        self.timeStretch = timeStretch ?? Self.defaultTimeStretch(for: subtype)
        elementProperties = ElementProperties(visible: visible)
    }

    /// What an absent `<timeStretch>` means in a MuseScore file: the subtype's `propertyDefault(TIME_STRETCH)`
    /// (`dom/fermata.cpp:194-210`), which MuseScore omits from the file. It differs from `defaultTimeStretch(for:)`,
    /// the value folino's menu and MusicXML import insert. Measured on MuseScore 4.7.4's MIDI export: Long and
    /// LongHenze 3.0 (tempo 1499999 µs/quarter over the bar), plain 2.0 (1000000), VeryShort 1.25 (625000),
    /// Short and ShortHenze 1.5 (750000), VeryLong 4.0 (2000000). An unknown subtype is read as the plain
    /// fermata (`Undefined` becomes Normal, `fermata.cpp:201-203`).
    public static func fileDefaultTimeStretch(for subtype: String) -> Double {
        switch subtype {
        case "fermataVeryShortAbove", "fermataVeryShortBelow":
            return 1.25
        case "fermataShortAbove", "fermataShortBelow",
             "fermataShortHenzeAbove", "fermataShortHenzeBelow":
            return 1.5
        case "fermataLongAbove", "fermataLongBelow",
             "fermataLongHenzeAbove", "fermataLongHenzeBelow":
            return 3.0
        case "fermataVeryLongAbove", "fermataVeryLongBelow":
            return 4.0
        default:
            return 2.0
        }
    }

    /// Subtype → default MIDI hold ratio. Mirrors MuseScore's
    /// per-symbol `Fermata::timeStretch` defaults.
    public static func defaultTimeStretch(for subtype: String) -> Double {
        switch subtype {
        case "fermataVeryShortAbove", "fermataVeryShortBelow",
             "fermataShortHenzeAbove", "fermataShortHenzeBelow":
            return 1.25
        case "fermataAbove", "fermataBelow",
             "fermataShortAbove", "fermataShortBelow":
            return 1.5
        case "fermataLongAbove", "fermataLongBelow",
             "fermataLongHenzeAbove", "fermataLongHenzeBelow":
            return 2.0
        case "fermataVeryLongAbove", "fermataVeryLongBelow":
            return 3.0
        default:
            return 1.5
        }
    }
}
