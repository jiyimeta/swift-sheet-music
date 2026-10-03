#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

extension FontMetricsProvider {
    /// Portable approximation: sum grapheme advances without cross-grapheme kerning or bidi shaping.
    /// Repeat each grapheme's starting offset over its interior UTF-16 positions.
    public func caretOffsets(text: String, font: LayoutFont) -> [CGFloat] {
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(text.utf16.count + 1)
        var cursor: CGFloat = 0
        for character in text {
            let grapheme = String(character)
            offsets.append(contentsOf: repeatElement(cursor, count: grapheme.utf16.count))
            cursor += typographicWidth(text: grapheme, font: font)
        }
        offsets.append(cursor)
        return offsets
    }

    public func characterIndex(forOffset offset: CGFloat, text: String, font: LayoutFont) -> Int {
        let offsets = caretOffsets(text: text, font: font)
        let boundaries = text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
        guard !offset.isNaN else { return 0 }
        // Clamp against the visual extent, not logical first/last: an RTL line can run backwards.
        let minimum = boundaries.map { offsets[$0] }.min() ?? 0
        let maximum = boundaries.map { offsets[$0] }.max() ?? 0
        let position = min(max(offset, minimum), maximum)
        var nearest = 0
        var distance = CGFloat.infinity
        for index in boundaries {
            let candidate = abs(offsets[index] - position)
            if candidate < distance {
                nearest = index
                distance = candidate
            }
        }
        return nearest
    }
}
