#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicBridgeCore
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// Independent outline oracle. It never calls a layout metrics or anchoring helper.
    enum TextInkOracle {
        static func font(face: String = "Edwin", size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
            let base = CTFontCreateWithName(face as CFString, size, nil)
            var traits: CTFontSymbolicTraits = []
            if bold { traits.insert(.boldTrait) }
            if italic { traits.insert(.italicTrait) }
            return traits.isEmpty ? base : CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
        }

        /// The platform UI face at a weight, italic through the font descriptor — how the CG parity renderer draws
        /// `FontID.system`, and how the Apple provider measures an empty face.
        static func systemFont(size: CGFloat, bold: Bool = false, semibold: Bool = false, italic: Bool = false)
            -> CTFont
        {
            #if os(macOS)
                let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : semibold ? .semibold : .regular)
                guard italic, let slanted = NSFont(
                    descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size,
                ) else { return base as CTFont }
                return slanted as CTFont
            #else
                let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : semibold ? .semibold : .regular)
                guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic)
                else { return base as CTFont }
                return UIFont(descriptor: descriptor, size: size) as CTFont
            #endif
        }

        /// The font a CG reader draws a `.text` / `.glyph` command in: its face id and the `setTextStyle` bits in
        /// force. `.system` is the UI face with the weight precedence bold → semibold → regular; the named faces take
        /// bold and italic as symbolic traits and ignore semibold, as `DrawProgramCGRenderer` does.
        static func font(fontID: DrawProgram.FontID, size: CGFloat, flags: UInt8) -> CTFont {
            let bold = flags & DrawCommand.TextStyleFlag.bold != 0
            let italic = flags & DrawCommand.TextStyleFlag.italic != 0
            switch fontID {
            case .system:
                return systemFont(
                    size: size, bold: bold, semibold: flags & DrawCommand.TextStyleFlag.semibold != 0, italic: italic,
                )
            case .smufl:
                return font(face: "Bravura", size: size, bold: bold, italic: italic)
            case .textRoman:
                return font(face: "Edwin", size: size, bold: bold, italic: italic)
            }
        }

        static func path(_ text: String, font: CTFont) -> CGPath? {
            let result = CGMutablePath()
            let stride = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            for (lineIndex, text) in text.components(separatedBy: "\n").enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
                for run in runs {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let value = attributes[kCTFontAttributeName] else { continue }
                    let runFont = unsafeBitCast(value as AnyObject, to: CTFont.self)
                    let count = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                    for index in 0 ..< count {
                        var shift = CGAffineTransform(
                            translationX: positions[index].x,
                            y: positions[index].y - CGFloat(lineIndex) * stride,
                        )
                        if let path = CTFontCreatePathForGlyph(runFont, glyphs[index], &shift) { result.addPath(path) }
                    }
                }
            }
            return result.isEmpty ? nil : result
        }
    }
#endif
