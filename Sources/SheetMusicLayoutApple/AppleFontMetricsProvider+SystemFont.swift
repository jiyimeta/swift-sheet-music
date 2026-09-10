import CoreText
import SheetMusicLayout
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension AppleFontMetricsProvider {
    /// Match the renderer's system font selection, including weight and italic.
    static func systemFont(for font: LayoutFont) -> CTFont {
        #if canImport(AppKit)
            let weight: NSFont.Weight = switch font.weight {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            }
            let base = NSFont.systemFont(ofSize: font.pointSize, weight: weight)
            guard font.isItalic,
                  let italic = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize)
            else { return base as CTFont }
            return italic as CTFont
        #else
            let weight: UIFont.Weight = switch font.weight {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            }
            let base = UIFont.systemFont(ofSize: font.pointSize, weight: weight)
            guard font.isItalic, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic)
            else { return base as CTFont }
            return UIFont(descriptor: descriptor, size: font.pointSize) as CTFont
        #endif
    }
}
