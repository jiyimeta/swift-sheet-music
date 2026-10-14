#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutElementShape {
    /// `textRect(text:font:origin:anchor:)` for typeset runs: the block's typographic box — its advance width and its
    /// stack height — placed by the same anchor conventions. The box hangs off
    /// `LayoutRichText.blockOrigin(at:anchor:)`, so a centered block is centered by its ink width exactly as
    /// `inkRect(at:anchor:)` and the renderers place it, while the extent stays the advance box the skyline reserves
    /// for plain text.
    static func textRect(rich: LayoutRichText, origin: CGPoint, anchor: TextAnchorConvention) -> CGRect {
        let unit = switch anchor {
        case .leadingCenter: CGPoint(x: 0, y: 0.5)
        case .bottomLeading: CGPoint(x: 0, y: 1)
        case .center: CGPoint(x: 0.5, y: 0.5)
        }
        let block = rich.blockOrigin(at: origin, anchor: unit)
        return CGRect(x: block.x, y: block.y, width: rich.size.width, height: rich.size.height)
    }
}
