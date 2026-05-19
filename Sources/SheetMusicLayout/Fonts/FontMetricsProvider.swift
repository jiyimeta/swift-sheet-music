import CoreGraphics
import Foundation

/// Font descriptor used by `FontMetricsProvider`. Identifies the face
/// (e.g. "Bravura", "Edwin", "" for system), the rendering point size,
/// and the weight when the face has multiple weights (lyrics use
/// semibold; SMuFL glyph fonts ignore weight).
public struct LayoutFont: Hashable, Sendable {
    public let face: String
    public let pointSize: CGFloat
    public let weight: FontWeight

    public init(
        face: String,
        pointSize: CGFloat,
        weight: FontWeight = .regular,
    ) {
        self.face = face
        self.pointSize = pointSize
        self.weight = weight
    }
}

public enum FontWeight: Sendable, Hashable {
    case regular
    case semibold
}

/// Ink-pixel extents of a typeset string. `leftBearing` is the offset
/// from the typographic origin to the leftmost inked pixel; `width`
/// is the horizontal extent of the inked region.
public struct InkBounds: Sendable {
    public let leftBearing: CGFloat
    public let width: CGFloat

    public init(leftBearing: CGFloat, width: CGFloat) {
        self.leftBearing = leftBearing
        self.width = width
    }
}

/// Platform-agnostic interface to font measurement. `SheetMusicLayout`
/// holds the protocol; concrete implementations live in
/// `SheetMusicLayoutApple` (CoreText) and a future
/// `SheetMusicLayoutAndroid`. A `StubFontMetricsProvider` provides
/// rectangle approximations so `LayoutEngine` can produce a
/// `LayoutDocument` on platforms with no real provider yet.
public protocol FontMetricsProvider: Sendable {
    func ascent(font: LayoutFont) -> CGFloat
    func descent(font: LayoutFont) -> CGFloat
    func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect?
    func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat
    func inkBounds(text: String, font: LayoutFont) -> InkBounds
}

/// Global injection point. Apple hosts trigger
/// `SheetMusicLayoutApple.install` (transitively via `SheetMusicUI` or
/// `SheetMusicPDF`); non-Apple hosts leave the Stub in place or assign
/// their own provider.
public enum FontMetrics {
    /// App-launch-time-once mutation; reader path is read-only. Same
    /// unchecked-Sendable rationale as the existing `bboxCache`/`fontCache`
    /// statics elsewhere in this target.
    public nonisolated(unsafe) static var provider: any FontMetricsProvider
        = StubFontMetricsProvider()
}

/// Rectangle approximations sized off the requested `pointSize`.
/// Numbers chosen to match Bravura's typical SMuFL proportions
/// (1 em = 4 sp; ascent ≈ 0.85 em; descent ≈ 0.25 em; glyph bbox
/// ≈ 1 em × 0.7 em). Good enough for `LayoutDocument` generation;
/// not pixel-accurate.
public struct StubFontMetricsProvider: FontMetricsProvider {
    public init() {}

    public func ascent(font: LayoutFont) -> CGFloat {
        font.pointSize * 0.85
    }

    public func descent(font: LayoutFont) -> CGFloat {
        font.pointSize * 0.25
    }

    public func glyphPathBoundingBox(
        font: LayoutFont, codepoint _: UInt16,
    ) -> CGRect? {
        CGRect(
            x: 0, y: 0,
            width: font.pointSize,
            height: font.pointSize * 0.7,
        )
    }

    public func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat {
        CGFloat(text.count) * font.pointSize * 0.5
    }

    public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        InkBounds(
            leftBearing: 0,
            width: typographicWidth(text: text, font: font),
        )
    }
}
