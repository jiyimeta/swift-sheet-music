#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation

    /// Independent outline oracle. It never calls a layout metrics or anchoring helper.
    enum TextInkOracle {
        static func font(face: String = "Edwin", size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
            let base = CTFontCreateWithName(face as CFString, size, nil)
            var traits: CTFontSymbolicTraits = []
            if bold { traits.insert(.boldTrait) }
            if italic { traits.insert(.italicTrait) }
            return traits.isEmpty ? base : CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
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
