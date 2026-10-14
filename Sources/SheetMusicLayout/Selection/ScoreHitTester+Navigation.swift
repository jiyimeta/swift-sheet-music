#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

@available(macOS 15.0, *)
extension ScoreHitTester {
    /// A marker's or jump's unpadded geometry: its runs' box, the one the skyline reserves
    /// (`LayoutElementShape.navigationLabelRect(for:)`), whatever the marker's kind. Empty for one without runs, which
    /// draws nothing; `nil` for any other element.
    func navigationRects(_ element: LayoutElement) -> [CGRect]? {
        switch element {
        case .marker, .jump: LayoutElementShape.navigationLabelRect(for: element).map { [$0] } ?? []
        default: nil
        }
    }

    /// Navigation marks are text, and take text's reach.
    func navigationUsesText(_ element: LayoutElement) -> Bool {
        switch element {
        case .marker, .jump: true
        default: false
        }
    }
}
