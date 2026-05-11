import SheetMusicCore
import SheetMusicLayout
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
@available(macOS 15.0, iOS 16.0, *)
enum ResolvedTextStyle {
    /// Reference spatium in points used by `engraving/style/styledef.cpp`
    /// for its `Sid::*FontSize` defaults.
    static let referenceSpatiumInPoints: CGFloat = 5.0

    /// Resolve `style + overrides` to a renderable description.
    static func resolve(
        _ style: TextStyleType,
        overrides: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) -> Resolution {
        let defaults = overrides.resolved(against: style)
        let pointSize = if defaults.spatiumDependent {
            CGFloat(defaults.size) * metrics.sp / referenceSpatiumInPoints
        } else {
            CGFloat(defaults.size)
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
        var ctFont: CTFont {
            var traits: CTFontSymbolicTraits = []
            if isBold { traits.insert(.boldTrait) }
            if isItalic { traits.insert(.italicTrait) }
            let base = CTFontCreateWithName(
                face as CFString, pointSize, nil,
            )
            if traits.isEmpty { return base }
            return CTFontCreateCopyWithSymbolicTraits(
                base, pointSize, nil, traits, traits,
            ) ?? base
        }
    }
}
