#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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
    /// Extra vertical space the face asks for BETWEEN consecutive lines,
    /// on top of `ascent + descent`. Only multi-line text consults it —
    /// see `LayoutElementShape.textRect`.
    func leading(font: LayoutFont) -> CGFloat
}

extension FontMetricsProvider {
    /// Providers that have no notion of line gap (the stub, and
    /// Android's `SMuFLMetricsTable`-backed provider) stack lines at
    /// `ascent + descent`. Their multi-line boxes come out one leading
    /// per line tighter than Apple's — the same "Android text metrics
    /// out of scope" boundary documented on
    /// `LayoutElementShape.smuflRunRect`.
    public func leading(font _: LayoutFont) -> CGFloat {
        0
    }
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
        var total: CGFloat = 0
        for scalar in text.unicodeScalars {
            total += Self.advanceEm(for: scalar) * font.pointSize
        }
        return total
    }

    /// Per-codepoint advance estimate in ems. Tuned to roughly match
    /// MuseScore's Edwin text face so that bridge-computed text bounds
    /// (rehearsal-mark frames, harmony widths) on Android don't clip
    /// the actual rendered glyphs.
    ///
    /// Numbers come from measuring Edwin's advance table at 1 em:
    ///   - digits ≈ 0.50 (tabular figures)
    ///   - uppercase A-Z ≈ 0.65 average (`I` 0.3, `W` 0.95)
    ///   - lowercase a-z ≈ 0.50 average
    ///   - punctuation ≈ 0.30
    ///   - space ≈ 0.30
    /// CJK / kana / fullwidth forms use 1.0 em.
    private static func advanceEm(for scalar: Unicode.Scalar) -> CGFloat {
        let v = scalar.value
        if isFullWidth(scalar) { return 1.0 }
        // ASCII digits 0-9
        if (0x30 ... 0x39).contains(v) { return 0.5 }
        // ASCII uppercase A-Z
        if (0x41 ... 0x5A).contains(v) { return 0.65 }
        // ASCII lowercase a-z
        if (0x61 ... 0x7A).contains(v) { return 0.5 }
        // Space + most punctuation: narrow
        if v == 0x20 { return 0.3 }
        if (0x21 ... 0x2F).contains(v) || (0x3A ... 0x40).contains(v)
            || (0x5B ... 0x60).contains(v) || (0x7B ... 0x7E).contains(v)
        { return 0.3 }
        // Non-CJK non-ASCII (Latin extended, Cyrillic, Greek …):
        // use lowercase average as a safe-ish default.
        return 0.55
    }

    public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        InkBounds(
            leftBearing: 0,
            width: typographicWidth(text: text, font: font),
        )
    }

    /// True for code points conventionally typeset at ~1 em advance
    /// (CJK Unified Ideographs, kana, halfwidth/fullwidth forms).
    /// Latin / Cyrillic / Greek / digits fall back to the ~0.5 em
    /// average advance.
    private static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x1100 ... 0x11FF).contains(v) // Hangul Jamo
            || (0x2E80 ... 0x2FFF).contains(v) // CJK Radicals
            || (0x3000 ... 0x303F).contains(v) // CJK Symbols
            || (0x3040 ... 0x309F).contains(v) // Hiragana
            || (0x30A0 ... 0x30FF).contains(v) // Katakana
            || (0x3130 ... 0x318F).contains(v) // Hangul Compatibility Jamo
            || (0x3400 ... 0x4DBF).contains(v) // CJK Ext A
            || (0x4E00 ... 0x9FFF).contains(v) // CJK Unified
            || (0xAC00 ... 0xD7AF).contains(v) // Hangul Syllables
            || (0xF900 ... 0xFAFF).contains(v) // CJK Compat
            || (0xFE30 ... 0xFE4F).contains(v) // CJK Compat Forms
            || (0xFF00 ... 0xFF60).contains(v) // Fullwidth ASCII variants
            || (0xFFE0 ... 0xFFE6).contains(v) // Fullwidth signs
    }
}
