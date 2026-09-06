import SheetMusicFoundation

/// A string-tuning instruction attached to a segment at the current voice
/// tick. C++: `mu::engraving::StringTunings` (`dom/stringtunings.h:30`), a
/// `StaffTextBase` stored as a staff-bound segment annotation. Its MSCX writer
/// and reader begin at `rw/write/twrite.cpp:3205` and
/// `rw/read460/tread.cpp:4217`.
///
/// **Content, not presentation.** The preset, visible-string order, optional
/// tuning data, and `text` are modeled; `<style>`, `<placement>`, `<offset>`,
/// font overrides, and the `StaffTextBase` channel and swing tags stay in
/// `preservedMarkup`. Inline markup inside `<text>` flattens to plain text, the
/// cross-cutting limitation described by the parity document's §7.1
/// text-content work.
public struct StringTunings: Sendable, Equatable {
    /// `<preset>`, or an empty string when absent.
    public var preset: String
    /// `<visibleStrings>` in file order.
    public var visibleStrings: [Int]
    /// The optional nested `<StringData>` tuning.
    public var stringData: StringData?
    /// The `<text>` payload, flattened to plain text.
    public var text: String
    /// Base element properties shared with every engravable element.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent, including text
    /// presentation, placement, channel, and swing properties.
    public var preservedMarkup: [PreservedXML]

    public init(
        preset: String = "",
        visibleStrings: [Int] = [],
        stringData: StringData? = nil,
        text: String = "",
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.preset = preset
        self.visibleStrings = visibleStrings
        self.stringData = stringData
        self.text = text
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}
