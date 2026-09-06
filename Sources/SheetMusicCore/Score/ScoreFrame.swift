#if canImport(CoreGraphics)
    import CoreGraphics
#elseif !os(WASI)
    // The one place in the package that reaches past `SheetMusicFoundation`
    // to the umbrella on purpose. On Android and Linux,
    // swift-corelibs-foundation is what declares `CGFloat` / `CGPoint`, and
    // the Android JNI bridge depends on getting *those* types rather than a
    // structurally identical local copy. `SheetMusicFoundation` resolves to
    // `FoundationEssentials` on both platforms, which carries neither.
    //
    // The `!os(WASI)` gate is what makes this safe: WebAssembly takes the
    // module's own declarations from `CGCompat+WASI.swift`, so the umbrella
    // never reaches the wasm binary and the ICU cost is not paid. Do not
    // widen the gate to `!canImport(CoreGraphics)`.
    // swiftlint:disable:next no_foundation_umbrella
    import Foundation
#endif

/// A page-level frame that holds free-form text — typically the
/// title block at the top of the score (`<VBox>` in MuseScore's
/// `.mscx`). Frames don't have notation; they reserve vertical
/// space and lay text inside it according to per-text style hints
/// (Title centered, Composer right-aligned, etc.).
///
/// A score can carry multiple frames between systems in MuseScore's
/// `MeasureBase` stream. `Score.blocks` preserves those positions;
/// `Score.titleFrame` exposes the leading vertical frame used by layout.
public struct ScoreFrame: Sendable, Equatable, Hashable {
    /// Height in spatium (sp) units — same scale MuseScore uses
    /// internally. The layout engine multiplies by `sp` to get
    /// points.
    public var heightSp: CGFloat
    public var texts: [FrameText]
    /// Source children that the typed frame model does not represent.
    /// This is fidelity, not semantics; no layout or editing pass reads it.
    public var preservedMarkup: [PreservedXML]

    public init(
        heightSp: CGFloat,
        texts: [FrameText],
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.heightSp = heightSp
        self.texts = texts
        self.preservedMarkup = preservedMarkup
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(heightSp)
        hasher.combine(texts)
    }
}

public struct FrameText: Sendable, Equatable, Hashable {
    /// MuseScore-style text role. The renderer uses this to pick a
    /// default position (Title centered, Composer right-aligned,
    /// etc.) and a default font size.
    public enum Style: String, Sendable, Equatable, Hashable {
        case title = "Title"
        case subtitle = "Subtitle"
        case composer = "Composer"
        case lyricist = "Lyricist"
        case other
    }

    public var style: Style
    public var text: String
    public var preservedTextMarkup: PreservedTextMarkup?
    /// Optional explicit (x, y) offset from MuseScore's `<offset>`
    /// element. Stored in millimetres — MuseScore's read path (see
    /// `read460/tread.cpp` `case P_TYPE::POINT`) interprets the
    /// XML value via `value * DPMM` for ABS offset types (the
    /// default for Title / Subtitle / Composer / Lyricist styles
    /// in `styledef.cpp`). The renderer multiplies by `72/25.4`
    /// to get typographic points.
    public var offsetMm: CGPoint?
    /// Per-element `<size>` override in typographic points. `nil`
    /// inherits the styledef default for `style`. MuseScore writes
    /// this child only when the element diverges from the role's
    /// font size (e.g. a custom-sized Lyricist used as a multi-line
    /// lyric column).
    public var fontSize: Double?
    /// Per-element `<align>` override (e.g. `<align>left,top</align>`
    /// on a Lyricist text to reposition it from the role default of
    /// bottom-left to top-left). `nil` inherits the role default
    /// resolved via `ScoreStyle`. MuseScore writes this child only
    /// when the element diverges from the style's alignment.
    public var align: TextAlign?

    public init(
        style: Style, text: String,
        offsetMm: CGPoint? = nil,
        fontSize: Double? = nil,
        align: TextAlign? = nil,
        preservedTextMarkup: PreservedTextMarkup? = nil,
    ) {
        self.style = style
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.offsetMm = offsetMm
        self.fontSize = fontSize
        self.align = align
    }
}
