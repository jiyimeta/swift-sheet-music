import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

/// Single source of truth that converts `(TextStyleType, optional
/// per-element overrides, current spatium)` into a SwiftUI `Font`.
///
/// MuseScore's reference spatium is 1.764 mm ≈ 5.0 pt. A
/// spatium-dependent text style with size *S* pt renders at
/// `S × (metrics.sp / 5.0)` pt, so the printed character height
/// scales with the staff. Non-spatium-dependent rows (title block,
/// header, footer, page number) ignore the staff size and render at
/// their literal pt size.
@available(macOS 15.0, *)
enum ResolvedTextStyle {
    /// Resolve `style + overrides` to a renderable description.
    ///
    /// The face, size, bold and italic are the ones the current metrics provider draws the style's font in
    /// (`RenderingTextFace`) when it draws it as another font — Edwin, for every face under the portable table — since
    /// that is the font a layout made under that provider measured the text in. Under CoreText it draws the font as
    /// asked, and the style's own face is used.
    static func resolve(
        _ style: TextStyleType,
        overrides: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) -> Resolution {
        let defaults = overrides.resolved(against: style)
        let pointSize = TextRoleStyle.fontSize(
            defaults: defaults, sp: metrics.sp,
        )
        let asked = LayoutFont(
            face: defaults.face, pointSize: pointSize,
            weight: defaults.style.contains(.bold) ? .bold : .regular, isItalic: defaults.style.contains(.italic),
        )
        if let substitute = RenderingTextFace.substitute(for: asked) {
            var drawnStyle = defaults.style.subtracting([.bold, .italic])
            if substitute.weight == .bold { drawnStyle.insert(.bold) }
            if substitute.isItalic { drawnStyle.insert(.italic) }
            return Resolution(
                face: substitute.face,
                pointSize: substitute.pointSize,
                style: drawnStyle,
                frameType: defaults.frameType,
                framePadding: CGFloat(defaults.framePadding) * metrics.sp,
            )
        }
        return Resolution(
            face: defaults.face,
            pointSize: pointSize,
            style: defaults.style,
            frameType: defaults.frameType,
            framePadding: CGFloat(defaults.framePadding) * metrics.sp,
        )
    }

    /// SwiftUI-ready description.
    struct Resolution {
        let face: String
        /// Final size in typographic points, ready to hand to
        /// `Font.custom`.
        let pointSize: CGFloat
        let style: FontStyleSet
        let frameType: TextFrameType
        /// Frame padding in points (pre-multiplied by the current
        /// spatium, since MuseScore stores it in spatium units).
        let framePadding: CGFloat

        var isBold: Bool {
            style.contains(.bold)
        }

        var isItalic: Bool {
            style.contains(.italic)
        }

        var isUnderline: Bool {
            style.contains(.underline)
        }

        var isStrike: Bool {
            style.contains(.strike)
        }

        /// Build the SwiftUI font.
        ///
        /// - When the named face is not registered with CoreText
        ///   (e.g. Edwin not bundled), SwiftUI silently falls back
        ///   to the system font, so rendering still proceeds.
        /// - Bold/italic are applied via the family-name modifiers
        ///   so they cascade through the system fallback too.
        var font: Font {
            var f = Font.custom(face, size: pointSize)
            if isBold { f = f.bold() }
            if isItalic { f = f.italic() }
            return f
        }

        /// CoreText flavour of `font`, for the CALayer renderer.
        /// Same fallback semantics as `font`: an unregistered face
        /// resolves to the platform default through CoreText's
        /// cascade list.
        ///
        /// Cached by (face, size, traits). The renderer reads `ctFont`
        /// per text run / per element (often inside per-run loops), so
        /// an uncached `CTFontCreateWithName` re-resolves the family
        /// name on every draw — the source of the per-page-turn
        /// main-thread stall and the CoreText "use PostScript names"
        /// performance notes. The metrics provider already memoizes its
        /// CTFonts; this mirrors that for the render path.
        var ctFont: CTFont {
            TextCTFontCache.shared.font(
                face: face,
                pointSize: pointSize,
                isBold: isBold,
                isItalic: isItalic,
            )
        }
    }
}

/// Process-wide cache of render-path `CTFont`s, keyed by face + size + bold/italic. Mirrors the metrics-path cache in
/// `AppleFontMetricsProvider`; together they ensure a given face/size font is created by CoreText once, not once per
/// text element per frame. `@unchecked Sendable` + `NSLock` because `CTFontCreateWithName` for an unregistered family
/// name can deadlock under concurrent access (same rationale as the metrics provider's lock).
@available(macOS 15.0, *)
private final class TextCTFontCache: @unchecked Sendable {
    static let shared = TextCTFontCache()

    private struct Key: Hashable {
        let face: String
        let pointSize: CGFloat
        let isBold: Bool
        let isItalic: Bool
    }

    private let lock = NSLock()
    private var fonts: [Key: CTFont] = [:]

    func font(
        face: String,
        pointSize: CGFloat,
        isBold: Bool,
        isItalic: Bool,
    ) -> CTFont {
        let key = Key(face: face, pointSize: pointSize, isBold: isBold, isItalic: isItalic)
        lock.lock()
        defer { lock.unlock() }
        if let cached = fonts[key] { return cached }
        var traits: CTFontSymbolicTraits = []
        if isBold { traits.insert(.boldTrait) }
        if isItalic { traits.insert(.italicTrait) }
        let base = CTFontCreateWithName(face as CFString, pointSize, nil)
        let resolved: CTFont = traits.isEmpty
            ? base
            : (CTFontCreateCopyWithSymbolicTraits(base, pointSize, nil, traits, traits) ?? base)
        fonts[key] = resolved
        return resolved
    }
}
