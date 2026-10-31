#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct RasterTextReaderTests {
        struct TestError: Error {}

        static func whitePage() -> GrayBitmap {
            GrayBitmap(pixels: [UInt8](repeating: 255, count: 100 * 800), width: 100, height: 800, dpi: 300)
        }

        static func line(
            _ text: String, x: Double, y: Double, width: Double, height: Double,
            characters: [OMRRecognizedCharacter] = [],
        ) -> OMRRecognizedLine {
            OMRRecognizedLine(
                text: text, confidence: 0.9, x: x, y: y, width: width, height: height, characters: characters,
            )
        }

        @Test func eachStripIsUpscaledAndBoxesMapBackToPagePixels() {
            let fake = FakeTextRecognizer { index, _ in
                guard index == 1 else { return [] }
                let char = OMRRecognizedCharacter(text: "a", x: 20, y: 40, width: 30, height: 20)
                return [Self.line("a", x: 20, y: 40, width: 60, height: 20, characters: [char])]
            }
            let lines = RasterTextReader.lines(
                in: Self.whitePage(), recognizer: fake, strips: 4, overlapPx: 10, scale: 2,
            )
            // Strip 1 region rows 190..<410 -> image height (410 - 190) * 2 = 440, width 200.
            #expect(fake.images.count == 4)
            #expect(fake.images[1].width == 200 && fake.images[1].height == 440)
            #expect(lines.count == 1)
            #expect(lines[0].rect == PixelRect(x: 10, y: 210, width: 30, height: 10))
            #expect(lines[0].characters[0].rect == PixelRect(x: 10, y: 210, width: 15, height: 10))
        }

        @Test func aLineInTheOverlapIsKeptOnce() {
            // Page-space line centre at row 202: strip 0's overlap (200..<210), strip 1's core (200..<400).
            // Strip 0 region starts at row 0, strip 1 region at row 190; image = (page - origin) * 2.
            let fake = FakeTextRecognizer { index, _ in
                switch index {
                case 0: [Self.line("from0", x: 20, y: 394, width: 60, height: 20)]
                case 1: [Self.line("from1", x: 20, y: 14, width: 60, height: 20)]
                default: []
                }
            }
            let lines = RasterTextReader.lines(
                in: Self.whitePage(), recognizer: fake, strips: 4, overlapPx: 10, scale: 2,
            )
            #expect(lines.count == 1)
            #expect(lines.first?.text == "from1")
            #expect(lines.first?.rect == PixelRect(x: 10, y: 197, width: 30, height: 10))
        }

        @Test func aThrowingStripIsSkippedAndNamed() {
            let fake = FakeTextRecognizer { index, _ in
                if index == 2 { throw TestError() }
                return index == 0 ? [Self.line("ok", x: 20, y: 40, width: 60, height: 20)] : []
            }
            var failures: [Int] = []
            let lines = RasterTextReader.lines(
                in: Self.whitePage(), recognizer: fake, strips: 4, overlapPx: 10, scale: 2,
                onStripFailure: { index, _ in failures.append(index) },
            )
            #expect(lines.count == 1)
            #expect(failures == [2])
        }

        static func widePage(width: Int, height: Int = 400) -> GrayBitmap {
            GrayBitmap(pixels: [UInt8](repeating: 255, count: width * height), width: width, height: height, dpi: 300)
        }

        @Test func aWidePageIsReadInColumnTiles() {
            let fake = FakeTextRecognizer()
            _ = RasterTextReader.lines(
                in: Self.widePage(width: 6000), recognizer: fake, strips: 1, overlapPx: 10, scale: 2,
                maxTileWidthPx: 2600,
            )
            // Cores [0, 2000), [2000, 4000), [4000, 6000); regions grown by 10 and clamped to [0, 6000).
            #expect(fake.images.map(\.width) == [4020, 4040, 4020])
            #expect(fake.images.allSatisfy { $0.height == 800 })
        }

        @Test func aCharacterIsKeptByTheColumnWhoseCoreHoldsIt() {
            // Five 10 px wide characters in page space (x, text). Two sit in column overlaps (centres 2003 and 3995),
            // so two tiles see each; only the tile whose core holds the centre may keep it.
            let page: [(x: Double, text: String)] = [(495, "a"), (1998, "b"), (2995, "c"), (3990, "d"), (4995, "e")]
            let regionLefts: [Double] = [0, 1990, 3990]
            let fake = FakeTextRecognizer { index, image in
                let left = regionLefts[index]
                let right = left + Double(image.width) / 2
                let seen = page.filter { $0.x >= left && $0.x + 10 <= right }
                let characters = seen.map {
                    OMRRecognizedCharacter(text: $0.text, x: ($0.x - left) * 2, y: 200, width: 20, height: 40)
                }
                guard let first = characters.first, let last = characters.last else { return [] }
                let lineWidth = last.x + last.width - first.x
                return [Self.line(
                    seen.map(\.text).joined(separator: " "), x: first.x, y: 200, width: lineWidth, height: 40,
                    characters: characters,
                )]
            }
            let lines = RasterTextReader.lines(
                in: Self.widePage(width: 6000), recognizer: fake, strips: 1, overlapPx: 10, scale: 2,
                maxTileWidthPx: 2600,
            )
            let characters = lines.flatMap(\.characters)
            #expect(characters.map(\.text).sorted() == ["a", "b", "c", "d", "e"])
            #expect(characters.map(\.rect.midX).sorted() == [500, 2003, 3000, 3995, 5000])
            // Tile 0 also saw b (centre 2003, past its core's end at 2000) and tile 2 also saw d (centre 3995, before
            // its core's start at 4000); each drops it, so the lines are a | b c d | e and no character is doubled. The
            // recognizer's spaces between kept characters survive: OCRTextGlyphs splits tokens on them.
            #expect(lines.map(\.text) == ["a", "b c d", "e"])
            #expect(lines[1].rect == PixelRect(x: 1998, y: 100, width: 2002, height: 20))
        }

        @Test func anA4WidthPageStaysOneColumn() {
            let fake = FakeTextRecognizer { index, _ in
                guard index == 1 else { return [] }
                let char = OMRRecognizedCharacter(text: "a", x: 20, y: 40, width: 30, height: 20)
                let other = OMRRecognizedCharacter(text: "b", x: 80, y: 40, width: 30, height: 20)
                return [Self.line("a b", x: 20, y: 40, width: 90, height: 20, characters: [char, other])]
            }
            let lines = RasterTextReader.lines(
                in: Self.widePage(width: 2480, height: 800), recognizer: fake, strips: 4, overlapPx: 10, scale: 2,
                maxTileWidthPx: 2600,
            )
            #expect(fake.images.count == 4)
            #expect(fake.images.allSatisfy { $0.width == 4960 })
            // One column: the recognizer's text (with its space) and rect pass through untouched.
            #expect(lines.map(\.text) == ["a b"])
            #expect(lines[0].rect == PixelRect(x: 10, y: 210, width: 45, height: 10))
        }

        @Test func noTextYieldsNoLines() {
            let fake = FakeTextRecognizer()
            let lines = RasterTextReader.lines(
                in: Self.whitePage(), recognizer: fake, strips: 4, overlapPx: 10, scale: 2,
            )
            #expect(lines.isEmpty)
        }
    }
#endif
