#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Spatium-aware font sizing for a logical text role.
///
/// MuseScore stores per-role font sizes in typographic points at a
/// reference spatium of 1.764 mm ≈ 5 pt. A spatium-dependent role with
/// size `S` pt renders at `S × (sp / 5)` so the printed character
/// height scales with the staff. Non-spatium-dependent rows (title
/// block, header, footer, page number) ignore the staff size and
/// render at their literal pt size.
///
/// Defined in `SheetMusicLayout` so both the Apple SwiftUI renderer
/// (via `ResolvedTextStyle`) and the Android `LayoutBridge` resolve
/// font sizes through the same constants.
public enum TextRoleStyle {
    /// Reference spatium in points used by MuseScore's
    /// `engraving/style/styledef.cpp` for its `Sid::*FontSize` defaults.
    public static let referenceSpatiumInPoints: CGFloat = 5.0

    /// Final font size in points for `style` at the given staff
    /// spatium. Wraps the `S × (sp / 5)` formula for spatium-dependent
    /// styles and falls back to the literal size for page-chrome
    /// styles.
    public static func fontSize(
        for style: TextStyleType, sp: CGFloat,
    ) -> CGFloat {
        fontSize(defaults: style.museScoreDefault, sp: sp)
    }

    /// Variant for callers that have already resolved per-element
    /// overrides into a `TextStyleDefaults`.
    public static func fontSize(
        defaults: TextStyleDefaults, sp: CGFloat,
    ) -> CGFloat {
        if defaults.spatiumDependent {
            CGFloat(defaults.size) * sp / referenceSpatiumInPoints
        } else {
            CGFloat(defaults.size)
        }
    }

    /// Convenience: pick the `TextStyleType` that matches a layout
    /// `TextMarkKind`. Returns nil for kinds without a corresponding
    /// MuseScore text role.
    public static func style(
        for kind: LayoutElement.TextMarkKind,
    ) -> TextStyleType {
        switch kind {
        case .dynamic: .dynamics
        case .tempo: .tempo
        case .lyrics: .lyricsOdd
        }
    }

    /// Horizontal anchor at which a text element is positioned. The
    /// concrete renderer maps these to its native API (SwiftUI's
    /// `UnitPoint` on Apple, manual X offset for `Canvas.drawText` on
    /// Android).
    public enum HorizontalAnchor: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    /// Horizontal anchor MuseScore uses to position the given role.
    /// Lyrics centre on the chord stem; everything else is leading-
    /// anchored by default.
    public static func horizontalAnchor(
        for style: TextStyleType,
    ) -> HorizontalAnchor {
        switch style {
        case .lyricsOdd, .lyricsEven: .center
        default: .leading
        }
    }
}
