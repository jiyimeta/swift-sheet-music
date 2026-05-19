import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

@available(macOS 15.0, *)
enum TextMarkRenderer {
    /// Dynamic marking (pp, p, mf, f, ff, …). MuseScore renders
    /// standard dynamics as SMuFL glyphs from the music font, NOT
    /// as Edwin italic text — the `Sid::dynamicsFontFace = "Edwin"`
    /// style row is only consulted for custom (non-symbol) text
    /// like "cresc." or "espressivo". The atomic-letter glyphs
    /// (U+E520..U+E526) carry the bold serif weight, which is why
    /// MuseScore's dynamics look much heavier than plain text.
    /// Reference: `dom/dynamic.cpp:49-101` (DYN_LIST templates) and
    /// `dom/textbase.cpp:879-913` (music-font selection at draw
    /// time, size = MUSICAL_SYMBOLS_DEFAULT_FONT_SIZE × 2 = 20 pt
    /// at default spatium ≈ 4 sp).
    static func drawDynamic(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) {
        if let glyphs = DynamicSymbolMap.glyphs(for: text) {
            drawDynamicGlyphs(
                context: &context, glyphs: glyphs,
                origin: origin, metrics: metrics,
            )
        } else {
            // Custom / non-symbol dynamic — fall back to Edwin
            // italic 10 pt (the style-row default).
            let style = ResolvedTextStyle.resolve(
                .dynamics, overrides: properties, metrics: metrics,
            )
            let resolved = context.resolve(
                Text(text)
                    .foregroundColor(.primary)
                    .font(style.font),
            )
            context.draw(resolved, at: origin, anchor: .leading)
        }
    }

    private static func drawDynamicGlyphs(
        context: inout GraphicsContext,
        glyphs: [Character],
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        // SMuFL music-font convention: 1 em = 4 sp. MuseScore's
        // `MUSICAL_SYMBOLS_DEFAULT_FONT_SIZE = 10 pt` × 2 = 20 pt
        // at default spatium (5 pt/sp) which is exactly 4 sp.
        let glyphSize = metrics.sp * 4
        let str = String(glyphs)
        let resolved = context.resolve(
            Text(str)
                .foregroundColor(.primary)
                .font(.custom(BravuraFont.familyName, size: glyphSize)),
        )
        // Anchor: glyph's baseline at `origin.y`; use SwiftUI
        // `.leading` (vertically centred) since callers position
        // dynamics at staff-relative Y already accounting for
        // glyph height.
        context.draw(resolved, at: origin, anchor: .leading)
    }

    /// Lyric syllable. MuseScore default: Edwin 10 pt normal,
    /// centred on the chord stem (anchor = `.center`).
    static func drawLyric(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        verse: Int = 0,
        metrics: StaffMetrics,
    ) {
        let style = ResolvedTextStyle.resolve(
            verse.isMultiple(of: 2) ? .lyricsOdd : .lyricsEven,
            overrides: properties, metrics: metrics,
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(.primary)
                .font(style.font),
        )
        context.draw(resolved, at: origin, anchor: .center)
    }

    /// Tempo indication ("♩ = 120"). MuseScore default: Edwin 12 pt bold.
    static func drawTempo(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) {
        let style = ResolvedTextStyle.resolve(
            .tempo, overrides: properties, metrics: metrics,
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(.primary)
                .font(style.font),
        )
        context.draw(resolved, at: origin, anchor: .leading)
    }
}
