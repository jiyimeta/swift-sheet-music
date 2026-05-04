import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum TextMarkRenderer {
    /// Dynamic marking (pp, p, mf, f, ff, …). MuseScore default:
    /// Edwin 10 pt italic (`Sid::dynamicsFontFace/Size/Style`).
    static func drawDynamic(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics
    ) {
        let style = ResolvedTextStyle.resolve(
            .dynamics, overrides: properties, metrics: metrics
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(.primary)
                .font(style.font))
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
        metrics: StaffMetrics
    ) {
        let style = ResolvedTextStyle.resolve(
            verse.isMultiple(of: 2) ? .lyricsOdd : .lyricsEven,
            overrides: properties, metrics: metrics
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(.primary)
                .font(style.font))
        context.draw(resolved, at: origin, anchor: .center)
    }

    /// Tempo indication ("♩ = 120"). MuseScore default: Edwin 12 pt bold.
    static func drawTempo(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics
    ) {
        let style = ResolvedTextStyle.resolve(
            .tempo, overrides: properties, metrics: metrics
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(.primary)
                .font(style.font))
        context.draw(resolved, at: origin, anchor: .leading)
    }
}
