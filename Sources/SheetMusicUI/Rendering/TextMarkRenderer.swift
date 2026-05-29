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
        color: Color = .primary,
        metrics: StaffMetrics,
    ) {
        let style = ResolvedTextStyle.resolve(
            verse.isMultiple(of: 2) ? .lyricsOdd : .lyricsEven,
            overrides: properties, metrics: metrics,
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(color)
                .font(style.font),
        )
        context.draw(resolved, at: origin, anchor: .center)
    }

    /// Tempo indication ("♩ = 120"). MuseScore default: Edwin 12 pt
    /// bold for the text portion + Bravura for the leading music
    /// symbol; runs come from `MusicTextRuns.runs`.
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
        // Inline Bravura symbol at the same point size as the
        // surrounding Edwin text — MuseScore renders metronome glyphs
        // proportional to the text, not at full SMuFL 1-em staff size.
        let glyphSize = style.pointSize
        var cursorX = origin.x
        for run in MusicTextRuns.runs(in: text) {
            let resolved: GraphicsContext.ResolvedText
            let font: LayoutFont
            switch run.kind {
            case .musicSymbol:
                resolved = context.resolve(
                    Text(run.text)
                        .foregroundColor(.primary)
                        .font(.custom(BravuraFont.familyName, size: glyphSize)),
                )
                font = LayoutFont(
                    face: BravuraFont.familyName, pointSize: glyphSize,
                )
            case .text:
                resolved = context.resolve(
                    Text(run.text)
                        .foregroundColor(.primary)
                        .font(style.font),
                )
                font = LayoutFont(
                    face: style.face, pointSize: style.pointSize,
                )
            }
            context.draw(
                resolved,
                at: CGPoint(x: cursorX, y: origin.y),
                anchor: .leading,
            )
            cursorX += FontMetrics.provider.typographicWidth(
                text: run.text, font: font,
            )
        }
    }
}
