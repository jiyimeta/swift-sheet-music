#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import Testing

    @Suite("Text ink provider outlines")
    struct TextInkProviderTests {
        private let _installApple = TestSupport.installApple

        @Test(arguments: ["g", "A", "A\ng", "A\n\ng", " ", "\n"], [0, 1, 2, 3])
        func matchesIndependentCoreTextOutlines(text: String, style: Int) throws {
            guard #available(macOS 15.0, *) else { return }
            let provider = AppleFontMetricsProvider()
            // Helvetica has a real bold member, so ignoring weight changes the oracle.
            let bold = style & 1 != 0
            let italic = style & 2 != 0
            let descriptor = LayoutFont(
                face: "Helvetica", pointSize: 20, weight: bold ? .bold : .regular, isItalic: italic,
            )
            let ct = TextInkOracle.font(face: "Helvetica", size: 20, bold: bold, italic: italic)
            let expected = TextInkOracle.path(text, font: ct)?.boundingBoxOfPath
            let actual = provider.textInkBounds(text: text, font: descriptor)
            if let expected {
                let actual = try #require(actual)
                #expect(abs(actual.minX - expected.minX) < 0.001)
                #expect(abs(actual.minY - expected.minY) < 0.001)
                #expect(abs(actual.maxX - expected.maxX) < 0.001)
                #expect(abs(actual.maxY - expected.maxY) < 0.001)
                let lines = text.components(separatedBy: "\n").count
                let typographicHeight = CGFloat(lines) * (CTFontGetAscent(ct) + CTFontGetDescent(ct))
                    + CGFloat(lines - 1) * CTFontGetLeading(ct)
                #expect(abs(actual.height - typographicHeight) > 0.5)
            } else {
                #expect(actual == nil)
            }
        }
    }
#endif
