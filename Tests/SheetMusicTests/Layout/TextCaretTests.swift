#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreText
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    import Testing

    @Suite("TextCaret")
    struct TextCaretTests {
        /// Registers Edwin before anything here measures it. `AppleFontMetricsProvider` caches one `CTFont` per
        /// `LayoutFont` for the whole process, so on a runner without Edwin installed, measuring "Edwin" first would
        /// cache the system-font fallback under the key the text-ink suites read (Edwin 20 pt is staff text at
        /// staff size 40) and put them a point or two off the renderer whenever this suite ran first.
        private let _installApple = TestSupport.installApple

        @available(macOS 15.0, *)
        @Test func coreTextPositionsIncludeKerningAndTraits() throws {
            let provider = AppleFontMetricsProvider()
            for font in [
                LayoutFont(face: "Edwin", pointSize: 20),
                LayoutFont(face: "Edwin", pointSize: 20, weight: .bold),
                LayoutFont(face: "Edwin", pointSize: 20, isItalic: true),
                LayoutFont(face: "Helvetica", pointSize: 20, weight: .bold),
                LayoutFont(face: "Helvetica", pointSize: 20, isItalic: true),
            ] {
                let text = "AV fi 日本語"
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [.init(kCTFontAttributeName as String): provider.renderingFont(for: font)],
                ))
                let offsets = provider.caretOffsets(text: text, font: font)
                #expect(offsets.count == text.utf16.count + 1)
                for index in 0 ... text.utf16.count {
                    #expect(abs(offsets[index] - CTLineGetOffsetForStringIndex(line, index, nil)) < 0.001)
                }
                // CoreText shares a kerning adjustment across its caret boundary, so AV's caret is not
                // exactly V's glyph origin. Compare glyph origins independently on an unkerned string.
                let glyphText = "H2 日本語"
                let glyphLine = CTLineCreateWithAttributedString(NSAttributedString(
                    string: glyphText,
                    attributes: [.init(kCTFontAttributeName as String): provider.renderingFont(for: font)],
                ))
                let glyphOffsets = provider.caretOffsets(text: glyphText, font: font)
                for run in try #require(CTLineGetGlyphRuns(glyphLine) as? [CTRun]) {
                    let count = CTRunGetGlyphCount(run)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    var indices = [CFIndex](repeating: 0, count: count)
                    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                    for index in 0 ..< count {
                        #expect(abs(glyphOffsets[indices[index]] - positions[index].x) < 0.001)
                    }
                }
            }
        }

        @available(macOS 15.0, *)
        @Test func unicodeHitTestingReturnsOnlyGraphemeBoundaries() throws {
            let font = LayoutFont(face: "Edwin", pointSize: 20)
            for provider in [AppleFontMetricsProvider(), StubFontMetricsProvider()] as [any FontMetricsProvider] {
                let text = "A😀e\u{301}👩‍👩‍👧‍👦Z"
                let legal = Set(text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count])
                let offsets = provider.caretOffsets(text: text, font: font)
                #expect(offsets.count == text.utf16.count + 1)
                for x in try stride(from: CGFloat(-10), through: #require(offsets.max()) + 10, by: 0.5) {
                    #expect(legal.contains(provider.characterIndex(forOffset: x, text: text, font: font)))
                }
                #expect(provider.characterIndex(forOffset: -1000, text: text, font: font) == 0)
                #expect(provider.characterIndex(forOffset: 10000, text: text, font: font) == text.utf16.count)
                #expect(provider.caretOffsets(text: "", font: font) == [0])
                #expect(provider.characterIndex(forOffset: 100, text: "", font: font) == 0)
            }
        }

        @available(macOS 15.0, *)
        @Test func bidirectionalHitTestingChoosesNearestLegalOffset() throws {
            let provider = AppleFontMetricsProvider()
            let font = LayoutFont(face: "", pointSize: 20)
            let text = "abc אבג def"
            let offsets = provider.caretOffsets(text: text, font: font)
            let legal = text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
            #expect(zip(offsets, offsets.dropFirst()).contains { $0 > $1 })
            for x in try stride(from: CGFloat(-20), through: #require(offsets.max()) + 20, by: 1) {
                let index = provider.characterIndex(forOffset: x, text: text, font: font)
                let nearestDistance = try #require(legal.map { abs(offsets[$0] - x) }.min())
                #expect(abs(abs(offsets[index] - x) - nearestDistance) < 0.001)
            }
        }

        @available(macOS 15.0, *)
        @Test func harmonyUsesInkOriginsAndTerminalGlyphAdvance() {
            let provider = AppleFontMetricsProvider()
            FontMetrics.$scopedProvider.withValue(provider) {
                let metrics = StaffMetrics(staffSize: 28)
                for name in ["C#7/Gbb", "C##"] {
                    let harmony = Harmony(name: name)
                    let runs = HarmonyRendering.runs(for: harmony, metrics: metrics)
                    let offsets = HarmonyRendering.caretOffsets(for: harmony, metrics: metrics)
                    let font = LayoutFont(
                        face: "Bravura", pointSize: HarmonyRendering.glyphPointSize(for: harmony, metrics: metrics),
                    )
                    guard let last = runs.last, case let .accidental(accidental) = last.kind else {
                        Issue.record("Expected accidental")
                        return
                    }
                    let glyph = String(accidental.codepoint)
                    let origin = CGFloat(last.x) - provider.inkBounds(text: glyph, font: font).leftBearing
                    let terminal = origin + provider.typographicWidth(text: glyph, font: font)
                    #expect(offsets.count == name.utf16.count + 1)
                    #expect(abs((offsets.last ?? .nan) - terminal) < 0.001)
                    #expect(abs(offsets[offsets.count - 2] - (origin + terminal) / 2) < 0.001)
                    let firstAccidental: HarmonyAccidental = name == "C##" ? .doubleSharp : .sharp
                    let firstBearing = provider.inkBounds(
                        text: String(firstAccidental.codepoint), font: font,
                    ).leftBearing
                    #expect(abs(offsets[1] - (CGFloat(runs[1].x) - firstBearing)) < 0.001)
                }
            }
        }

        @available(macOS 15.0, *)
        @Test func harmonyTextCaretUsesTheRenderedInkBearing() {
            let provider = AppleFontMetricsProvider()
            FontMetrics.$scopedProvider.withValue(provider) {
                let metrics = StaffMetrics(staffSize: 28)
                let harmony = Harmony(name: "AV fi", properties: TextProperties(face: "Helvetica", style: [.italic]))
                let font = TextInkGeometry.font(for: harmony.styleType, overrides: harmony.properties, metrics: metrics)
                let offsets = HarmonyRendering.caretOffsets(for: harmony, metrics: metrics)
                let textOffsets = provider.caretOffsets(text: harmony.name, font: font)
                let bearing = provider.inkBounds(text: harmony.name, font: font).leftBearing
                for index in offsets.indices {
                    #expect(abs(offsets[index] - (textOffsets[index] - bearing)) < 0.001)
                }
                #expect(HarmonyRendering.caretOffsets(for: Harmony(name: ""), metrics: metrics) == [0])
            }
        }

        @available(macOS 15.0, *)
        @Test func generatedRootBassAndParenthesesDoNotAddNameIndices() {
            FontMetrics.$scopedProvider.withValue(AppleFontMetricsProvider()) {
                let metrics = StaffMetrics(staffSize: 28)
                let harmony = Harmony(name: "m7", rootTpc: 12, bassTpc: 15, leftParen: true, rightParen: true)
                let full = Harmony(name: "(Bbm7/G)")
                let offsets = HarmonyRendering.caretOffsets(for: harmony, metrics: metrics)
                let fullOffsets = HarmonyRendering.caretOffsets(for: full, metrics: metrics)
                #expect(offsets.count == 3)
                #expect(offsets == Array(fullOffsets[3 ... 5]))
                #expect(offsets[0] > 0)
            }
        }
    }
#endif
