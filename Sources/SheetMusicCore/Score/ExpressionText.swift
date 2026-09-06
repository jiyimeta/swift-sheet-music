import SheetMusicFoundation

/// An expression instruction attached to a segment at the current voice tick.
/// C++: `mu::engraving::Expression` (`dom/expression.h:30`), a `TextBase`
/// stored as a segment annotation.
///
/// **Named `ExpressionText`, not `Expression`.** `SheetMusicFoundation`
/// re-exports `Foundation`, which since the Predicate API ships its own
/// `Expression<each Input, Output>`; a bare `Expression` here is ambiguous for
/// type lookup in every portable target. The `-Text` suffix also matches
/// `StaffText` / `SystemText`. The MSCX tag stays `<Expression>`.
///
/// **Content, not presentation.** `text` and `snapToDynamics` are modeled;
/// `<style>`, font overrides, `<voiceAssignment>`, `<direction>`, and
/// `<centerBetweenStaves>` stay in `preservedMarkup`; the shared base owns
/// `<offset>` and `<placement>` through `elementProperties`. Inline markup
/// inside `<text>` is carried opaquely beside the flattened plain text.
/// `<color>` is decoded into `elementProperties` but not
/// re-emitted — the decode-only gap documented by `ElementProperties+MSCX`,
/// shared with `Fingering` and `ChordOrnament`, and closed only by migrating
/// those encoders to `elementProperties.color`.
public struct ExpressionText: Sendable, Equatable {
    /// The `<text>` payload, flattened to plain text.
    public var text: String
    public var preservedTextMarkup: PreservedTextMarkup?
    /// `<snapToDynamics>`. `nil` when the tag is absent — MuseScore writes it
    /// only when the value is unstyled, so absent means "follow the style".
    public var snapToDynamics: Bool?
    /// Base element properties shared with every engravable element, including
    /// the spatium-unit `<offset>`.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent, including text
    /// presentation and voice-assignment properties.
    public var preservedMarkup: [PreservedXML]

    public init(
        text: String,
        snapToDynamics: Bool? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
        preservedTextMarkup: PreservedTextMarkup? = nil,
    ) {
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.snapToDynamics = snapToDynamics
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}
