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

        @Test func noTextYieldsNoLines() {
            let fake = FakeTextRecognizer()
            let lines = RasterTextReader.lines(
                in: Self.whitePage(), recognizer: fake, strips: 4, overlapPx: 10, scale: 2,
            )
            #expect(lines.isEmpty)
        }
    }
#endif
