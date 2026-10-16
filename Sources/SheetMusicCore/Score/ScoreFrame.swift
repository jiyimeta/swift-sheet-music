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
import SheetMusicFoundation

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
    /// Gap above the frame in spatium; `nil` is MS's default of 7 sp (`box.cpp:255-258`).
    public var topGapSp: CGFloat?
    /// Gap below the frame in spatium; `nil` is MS's default of 7 sp.
    public var bottomGapSp: CGFloat?
    /// MS `boxAutoSize`; `nil` is the MS default, true (`box.cpp:265-266`). Optional so a written `1` is written
    /// back like a written gap.
    public var autoSize: Bool?
    /// The `<Image>` children (MS `image.cpp`); the bytes live in `Score.pictures`.
    public var images: [FrameImage]

    /// Whether the frame carries a page break (a `LayoutBreak` whose `subtype` is `page`). Computed from
    /// `preservedMarkup` so it cannot go stale when a host edits the bag.
    public var pageBreakAfter: Bool {
        preservedMarkup.hasPageBreak
    }

    public init(
        heightSp: CGFloat,
        texts: [FrameText],
        preservedMarkup: [PreservedXML] = [],
        topGapSp: CGFloat? = nil,
        bottomGapSp: CGFloat? = nil,
        autoSize: Bool? = nil,
        images: [FrameImage] = [],
    ) {
        self.heightSp = heightSp
        self.texts = texts
        self.preservedMarkup = preservedMarkup
        self.topGapSp = topGapSp
        self.bottomGapSp = bottomGapSp
        self.autoSize = autoSize
        self.images = images
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(heightSp)
        hasher.combine(texts)
        hasher.combine(topGapSp)
        hasher.combine(bottomGapSp)
        hasher.combine(autoSize)
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
    /// The `<style>` value as written when it names none of the modeled roles (a TBox's `frame`, a user style); `nil`
    /// when the style is modeled or absent.
    public var otherStyleName: String?

    public init(
        style: Style, text: String,
        offsetMm: CGPoint? = nil,
        fontSize: Double? = nil,
        align: TextAlign? = nil,
        preservedTextMarkup: PreservedTextMarkup? = nil,
        otherStyleName: String? = nil,
    ) {
        self.otherStyleName = otherStyleName
        self.style = style
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.offsetMm = offsetMm
        self.fontSize = fontSize
        self.align = align
    }

    /// The text on one line: each `\n` (a run of them too) becomes one space, and the ends are trimmed.
    public var singleLineText: String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingWhitespaceAndNewlines()
    }
}
