#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension HarmonyRendering {
    /// UTF-16 boundaries of `harmony.name`, relative to the first displayed run's ink origin (x = 0).
    /// Generated roots, basses and wrapping parentheses affect placement but add no entries. Text uses the
    /// resolved font's shaping; `bb` / `##` split their single glyph advance at its midpoint. A shared run
    /// boundary uses the next run's start, while the terminal boundary excludes the synthetic spacing gap.
    /// Ligature/bidi offsets can repeat or run backwards; callers must restrict hit testing to grapheme boundaries.
    public static func caretOffsets(for harmony: Harmony, metrics: StaffMetrics) -> [CGFloat] {
        let displayName = displayedName(for: harmony)
        let slices = parseSlices(name: displayName, harmonyType: harmony.harmonyType)
        let runs = runs(for: harmony, metrics: metrics)
        let provider = FontMetrics.provider
        let textFont = TextInkGeometry.font(for: harmony.styleType, overrides: harmony.properties, metrics: metrics)
        let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: glyphPointSize(for: harmony, metrics: metrics))
        var offsets = [CGFloat](repeating: 0, count: displayName.utf16.count + 1)
        var sourceIndex = 0
        for (slice, run) in zip(slices, runs) {
            let localOffsets: [CGFloat]
            let content: String
            let font: LayoutFont
            switch slice {
            case let .text(text):
                content = text
                font = textFont
                localOffsets = provider.caretOffsets(text: text, font: font)
            case let .accidental(accidental):
                content = String(accidental.codepoint)
                font = glyphFont
                let count = accidental == .doubleFlat || accidental == .doubleSharp ? 2 : 1
                let advance = provider.typographicWidth(text: content, font: font)
                localOffsets = (0 ... count).map { advance * CGFloat($0) / CGFloat(count) }
            }
            let baseline = CGFloat(run.x) - provider.inkBounds(text: content, font: font).leftBearing
            for (index, offset) in localOffsets.enumerated() {
                offsets[sourceIndex + index] = baseline + offset
            }
            sourceIndex += localOffsets.count - 1
        }
        let start = displayedPrefix(for: harmony).utf16.count
        return Array(offsets[start ... start + harmony.name.utf16.count])
    }
}
