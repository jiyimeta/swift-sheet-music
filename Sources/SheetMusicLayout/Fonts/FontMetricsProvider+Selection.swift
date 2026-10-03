#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

extension FontMetricsProvider {
    /// Conservative fallback for providers without visual run information.
    public func selectionOffsets(text: String, font: LayoutFont, range: Range<Int>) -> [ClosedRange<CGFloat>] {
        let lower = max(0, range.lowerBound)
        let upper = min(text.utf16.count, range.upperBound)
        guard lower < upper else { return [] }
        let offsets = caretOffsets(text: text, font: font)[lower ... upper]
        guard let start = offsets.min(), let end = offsets.max() else { return [] }
        return [start ... end]
    }
}
