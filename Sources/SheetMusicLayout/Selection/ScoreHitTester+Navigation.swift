#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

@available(macOS 15.0, *)
extension ScoreHitTester {
    /// Unpadded navigation geometry. Glyph variants must never fall back to label text:
    /// missing glyph ink means no hit, because the renderer draws a glyph, not that label.
    func navigationRects(_ element: LayoutElement) -> [CGRect]? {
        if case let .marker(kind, text, origin, _) = element,
           case let .glyph(codepoint) = MarkerGlyph.variant(for: kind, text: text)
        {
            return glyphInkRects([(codepoint, origin)])
        }
        guard let textElement = navigationTextElement(element),
              let kind = LayoutElementShape.kind(of: textElement)
        else { return nil }
        return LayoutElementShape.autoplacedRects(for: textElement, kind: kind, metrics: document.metrics)
    }

    /// Navigation text uses the shipped text padding; glyph markers use their unpadded ink boxes.
    func navigationUsesText(_ element: LayoutElement) -> Bool {
        navigationTextElement(element) != nil
    }

    private func navigationTextElement(_ element: LayoutElement) -> LayoutElement? {
        switch element {
        case .jump:
            return element
        case let .marker(kind, text, origin, identity):
            guard case let .text(label) = MarkerGlyph.variant(for: kind, text: text) else { return nil }
            // Measure exactly the label the renderer draws, including Fine / D.C. fallback labels.
            return .marker(kind: kind, text: label, origin: origin, identity: identity)
        default:
            return nil
        }
    }
}
