#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif
import CoreText
import SheetMusic
import SheetMusicLayout

#if canImport(AppKit)
    typealias PlatformFont = NSFont
#else
    typealias PlatformFont = UIFont
#endif

/// Resolves the same public role defaults used by the live CALayer
/// renderers. The chord-symbol approximation is documented at its role
/// mapping in `ScoreTextEntryOverlay`.
struct EngravedTextFieldFont {
    let layoutFont: LayoutFont
    let platformFont: PlatformFont
    let ctFont: CTFont
    let pointSize: CGFloat
    let frameType: TextFrameType

    init(style: TextStyleType, sp: CGFloat) {
        let defaults = style.museScoreDefault
        pointSize = TextRoleStyle.fontSize(for: style, sp: sp)
        frameType = defaults.frameType
        layoutFont = LayoutFont(
            face: defaults.face,
            pointSize: pointSize,
            weight: defaults.style.contains(.bold) ? .bold : .regular,
        )
        var traits: CTFontSymbolicTraits = []
        if defaults.style.contains(.bold) {
            traits.insert(.boldTrait)
        }
        if defaults.style.contains(.italic) {
            traits.insert(.italicTrait)
        }
        let base = CTFontCreateWithName(
            defaults.face as CFString,
            pointSize,
            nil,
        )
        ctFont = traits.isEmpty
            ? base
            : CTFontCreateCopyWithSymbolicTraits(
                base,
                pointSize,
                nil,
                traits,
                traits,
            ) ?? base

        platformFont = Self.resolvePlatformFont(
            face: defaults.face,
            pointSize: pointSize,
            isBold: defaults.style.contains(.bold),
            isItalic: defaults.style.contains(.italic),
        )
    }

    private static func resolvePlatformFont(
        face: String,
        pointSize: CGFloat,
        isBold: Bool,
        isItalic: Bool,
    ) -> PlatformFont {
        #if canImport(AppKit)
            var appKitFont = NSFont(name: face, size: pointSize)
                ?? NSFont.systemFont(ofSize: pointSize)
            if isBold {
                appKitFont = NSFontManager.shared.convert(
                    appKitFont,
                    toHaveTrait: .boldFontMask,
                )
            }
            if isItalic {
                appKitFont = NSFontManager.shared.convert(
                    appKitFont,
                    toHaveTrait: .italicFontMask,
                )
            }
            return appKitFont
        #else
            var uiKitFont = UIFont(name: face, size: pointSize)
                ?? UIFont.systemFont(ofSize: pointSize)
            var descriptorTraits: UIFontDescriptor.SymbolicTraits = []
            if isBold {
                descriptorTraits.insert(.traitBold)
            }
            if isItalic {
                descriptorTraits.insert(.traitItalic)
            }
            if !descriptorTraits.isEmpty,
               let descriptor = uiKitFont.fontDescriptor.withSymbolicTraits(
                   descriptorTraits,
               )
            {
                uiKitFont = UIFont(
                    descriptor: descriptor,
                    size: pointSize,
                )
            }
            return uiKitFont
        #endif
    }
}
