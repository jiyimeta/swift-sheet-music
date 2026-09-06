import SheetMusicFoundation

/// A thoroughbass figure attached to a segment at the current voice tick.
/// C++: `mu::engraving::FiguredBass` (`dom/figuredbass.h:246`), a
/// `TextBase` stored as a segment annotation.
///
/// MuseScore writes one of two payloads from the same version: parsed figures
/// become `items`, while text that could not be parsed remains in `text`.
/// `<onNote>` has an inverted omission default: the writer emits it only when
/// false, so an absent tag means `true`. An absent `<ticks>` remains absent
/// here rather than synthesizing the upstream zero value.
public struct FiguredBass: Sendable, Equatable {
    /// Parsed `<FiguredBassItem>` children in document order.
    public var items: [FiguredBassItem]
    /// The authoritative raw `<text>` only when `items` is empty.
    ///
    /// When items are present, MuseScore rebuilds normalized text from them
    /// and overwrites the file's text (`rw/read460/tread.cpp:1440-1442`). The
    /// decoder therefore leaves this empty for the item representation.
    public var text: String
    /// `<onNote>`. An absent tag means `true`.
    public var isOnNote: Bool
    /// `<ticks>`, or `nil` when the tag is absent or malformed.
    public var ticks: Fraction?
    /// Base element properties shared with every engravable element.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent, including text
    /// presentation properties.
    public var preservedMarkup: [PreservedXML]

    public init(
        items: [FiguredBassItem] = [],
        text: String = "",
        isOnNote: Bool = true,
        ticks: Fraction? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.items = items
        self.text = text
        self.isOnNote = isOnNote
        self.ticks = ticks
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}
