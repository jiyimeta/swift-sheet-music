#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    import Testing

    @Suite("AppleFontMetricsProvider")
    struct AppleFontMetricsProviderTests {
        private let bravuraEm = LayoutFont(face: "Bravura", pointSize: 4)

        @available(macOS 15.0, iOS 16.0, *)
        @Test func ascentIsPositiveForBravura() {
            // Bravura's font-wide ascent should be well above zero at any
            // point size. Exact value is font-dependent — assert positivity
            // and rough scale only.
            let provider = AppleFontMetricsProvider()
            let a = provider.ascent(font: bravuraEm)
            #expect(a > 0)
            #expect(a < 20)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func descentIsPositiveForBravura() {
            let provider = AppleFontMetricsProvider()
            let d = provider.descent(font: bravuraEm)
            #expect(d > 0)
            #expect(d < 20)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func fermataAboveHasGlyphBoundingBox() {
            // U+E4C0 = fermataAbove. The glyph exists in Bravura with a
            // non-trivial bounding box.
            let provider = AppleFontMetricsProvider()
            let bbox = provider.glyphPathBoundingBox(
                font: bravuraEm, codepoint: 0xE4C0,
            )
            #expect(bbox != nil)
            if let bbox {
                #expect(bbox.width > 0)
                #expect(bbox.height > 0)
            }
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func missingCodepointReturnsNil() {
            // 0xE000 is brace — exists. 0x0001 (SOH) does not exist as a
            // SMuFL glyph in Bravura; provider should report nil.
            let provider = AppleFontMetricsProvider()
            let bbox = provider.glyphPathBoundingBox(
                font: bravuraEm, codepoint: 0x0001,
            )
            #expect(bbox == nil)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func typographicWidthIsPositiveForKnownString() {
            let provider = AppleFontMetricsProvider()
            let font = LayoutFont(face: "", pointSize: 10, weight: .semibold)
            let w = provider.typographicWidth(text: "Pa", font: font)
            #expect(w > 0)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func inkBoundsHaveNonZeroWidth() {
            let provider = AppleFontMetricsProvider()
            let font = LayoutFont(face: "", pointSize: 12)
            let ink = provider.inkBounds(text: "C2", font: font)
            #expect(ink.width > 0)
        }

        /// The per-string answers are cached by (text, font). Asked twice, each must still be what CoreText says
        /// for a line set in the provider's own `CTFont` — the second answer comes from the cache.
        @available(macOS 15.0, iOS 16.0, *)
        @Test(arguments: ["Pa", "glo", "Cm7(♭5)", "歌詞", "", "a\nb"])
        func cachedTextAnswersMatchCoreText(text: String) {
            let provider = AppleFontMetricsProvider()
            let font = LayoutFont(face: "", pointSize: 11, weight: .semibold)
            let ct = provider.renderingFont(for: font)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ct],
            ) as CFAttributedString)
            let width = text.isEmpty ? 0 : CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let image = CTLineGetImageBounds(line, nil)
            for _ in 0 ..< 2 {
                #expect(provider.typographicWidth(text: text, font: font) == width)
                let ink = provider.inkBounds(text: text, font: font)
                #expect(ink.leftBearing == (text.isEmpty ? 0 : image.origin.x))
                #expect(ink.width == (text.isEmpty ? 0 : image.width))
            }
            let firstBox = provider.textInkBounds(text: text, font: font)
            #expect(provider.textInkBounds(text: text, font: font) == firstBox)
            #expect((firstBox == nil) == text.isEmpty)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func providerIsParallelSafe() async {
            // Stress the internal lock: same provider called from many
            // concurrent tasks shouldn't deadlock or crash.
            let provider = AppleFontMetricsProvider()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 32 {
                    group.addTask {
                        _ = provider.glyphPathBoundingBox(
                            font: bravuraEm, codepoint: 0xE4C0,
                        )
                        _ = provider.typographicWidth(
                            text: "Cm7", font: LayoutFont(face: "", pointSize: 12),
                        )
                    }
                }
            }
        }
    }
#endif
