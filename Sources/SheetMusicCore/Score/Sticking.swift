import SheetMusicFoundation

/// A sticking instruction attached to a segment at the current voice tick.
/// C++: `mu::engraving::Sticking` (`dom/sticking.h:34`), a bare `TextBase`
/// stored as a segment annotation.
///
/// **Content, not presentation.** `text` is the annotation's modeled payload;
/// `<style>` and font overrides stay in `preservedMarkup`; the shared base owns
/// `<offset>` and `<placement>` through `elementProperties`. Inline markup
/// inside `<text>` is carried opaquely beside the flattened plain text.
/// `<color>` is decoded into `elementProperties` but not
/// re-emitted — the decode-only gap documented by `ElementProperties+MSCX`,
/// shared with `Fingering` and `ChordOrnament`, and closed only by migrating
/// those encoders to `elementProperties.color`.
public struct Sticking: Sendable, Equatable {
    /// The `<text>` payload, flattened to plain text.
    public var text: String
    public var preservedTextMarkup: PreservedTextMarkup?
    /// Base element properties shared with every engravable element, including
    /// the spatium-unit `<offset>`.
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
        text: String,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
        preservedTextMarkup: PreservedTextMarkup? = nil,
    ) {
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}
