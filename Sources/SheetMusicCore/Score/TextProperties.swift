import SheetMusicFoundation

/// Per-element font overrides parsed from MSCX. Any field left `nil`
/// inherits from the element's `TextStyleType` row in
/// `TextStyleDefaults`. Mirrors the optional `<face>`, `<size>`,
/// `<bold>`, `<italic>`, `<underline>`, `<strike>` and `<frameType>`
/// children that MuseScore writes when the element diverges from
/// its style.
///
/// C++: subset of `mu::engraving::TextBase` per-property flags
/// (`engraving/dom/textbase.cpp`).
public struct TextProperties: Sendable, Equatable {
    public var face: String?
    /// Points. Always typographic points; the renderer scales by
    /// spatium when the role's `spatiumDependent` is true.
    public var size: Double?
    public var style: FontStyleSet?
    public var frameType: TextFrameType?
    /// Padding inside the frame, in spatium units.
    public var framePadding: Double?

    public init(
        face: String? = nil,
        size: Double? = nil,
        style: FontStyleSet? = nil,
        frameType: TextFrameType? = nil,
        framePadding: Double? = nil,
    ) {
        self.face = face
        self.size = size
        self.style = style
        self.frameType = frameType
        self.framePadding = framePadding
    }

    /// True when no fields are set (the element should fully inherit
    /// from `TextStyleType`).
    public var isEmpty: Bool {
        face == nil && size == nil && style == nil
            && frameType == nil && framePadding == nil
    }

    /// True when a field that changes the glyphs themselves — face, size or style — is set. The frame fields do
    /// not count: they box the text, they do not change how it is measured or drawn. Layout takes its override
    /// path only when this is true, so a score whose text carries no font override lays out exactly as it did
    /// before overrides were honored.
    package var hasFontOverride: Bool {
        face != nil || size != nil || style != nil
    }

    /// The three font fields alone, with the frame fields dropped — what a layout element carries to its
    /// renderers, none of which draws `frameType` or `framePadding` from it.
    package var fontOverrides: TextProperties {
        TextProperties(face: face, size: size, style: style)
    }

    /// Convenience: resolve each field against `style`'s row in
    /// `TextStyleDefaults`, returning a fully-populated
    /// `TextStyleDefaults` value. Mirrors MuseScore's per-property
    /// fallback model.
    public func resolved(against style: TextStyleType) -> TextStyleDefaults {
        var d = style.museScoreDefault
        if let face { d.face = face }
        if let size { d.size = size }
        if let s = self.style { d.style = s }
        if let f = frameType { d.frameType = f }
        if let p = framePadding { d.framePadding = p }
        return d
    }
}
