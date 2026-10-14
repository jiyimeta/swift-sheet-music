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
    /// at default spatium ≈ 4 sp). A dynamic with its own text draws its runs (`LayoutRichText.dynamic`) instead.
    static func drawDynamic(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        richText: LayoutRichText? = nil,
        metrics: StaffMetrics,
    ) {
        if let richText {
            TextInkRenderer.drawRich(
                context: &context, richText: richText, origin: origin, anchor: LayoutRichText.anchor(for: .dynamic),
                color: .primary,
            )
            return
        }
        if let glyphString = DynamicSymbolMap.glyphString(for: text) {
            drawDynamicGlyphs(
                context: &context, glyphString: glyphString,
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
        glyphString: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        // SMuFL music-font convention: 1 em = 4 sp. MuseScore's
        // `MUSICAL_SYMBOLS_DEFAULT_FONT_SIZE = 10 pt` × 2 = 20 pt
        // at default spatium (5 pt/sp) which is exactly 4 sp.
        let glyphSize = metrics.sp * 4
        let resolved = context.resolve(
            Text(glyphString)
                .foregroundColor(.primary)
                .font(.custom(SMuFLFamily.bravura, size: glyphSize)),
        )
        // Anchor: glyph's baseline at `origin.y`; use SwiftUI
        // `.leading` (vertically centered) since callers position
        // dynamics at staff-relative Y already accounting for
        // glyph height.
        context.draw(resolved, at: origin, anchor: .leading)
    }

    /// Lyric syllable. MuseScore default: Edwin 10 pt normal,
    /// centered on the chord stem (anchor = `.center`).
    static func drawLyric(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        verse: Int = 0,
        color: Color = .primary,
        richText: LayoutRichText? = nil,
        metrics: StaffMetrics,
    ) {
        if let richText {
            TextInkRenderer.drawRich(
                context: &context, richText: richText, origin: origin, anchor: LayoutRichText.anchor(for: .lyric),
                color: color,
            )
            return
        }
        let style = ResolvedTextStyle.resolve(
            verse.isMultiple(of: 2) ? .lyricsOdd : .lyricsEven,
            overrides: properties, metrics: metrics,
        )
        TextInkRenderer.draw(
            context: &context, text: text, font: style.ctFont,
            origin: origin, anchor: CGPoint(x: 0.5, y: 0.5), color: color,
        )
    }

    /// A tempo marking: its typeset runs — the metronome glyph a Bravura symbol run at the tempo style's symbol size —
    /// or, for an element built without them, its plain text typeset the same way (`LayoutRichText.tempoText`).
    /// `properties` and `color` are the marking's font override and ink.
    static func drawTempo(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        color: Color = .primary,
        richText: LayoutRichText? = nil,
        metrics: StaffMetrics,
    ) {
        TextInkRenderer.drawRich(
            context: &context,
            richText: richText ?? LayoutRichText.tempoText(text, properties: properties, metrics: metrics),
            origin: origin, anchor: LayoutRichText.anchor(for: .tempo), color: color,
        )
    }
}
