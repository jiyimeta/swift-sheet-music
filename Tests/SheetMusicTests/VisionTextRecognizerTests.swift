#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import SheetMusicOMRModel
    import SheetMusicPDF
    import Testing

    struct VisionTextRecognizerTests {
        private static let width = 600
        private static let height = 120

        /// Draws `text` black on white into a gray bitmap, the same layout `OMRTextImage` documents.
        private static func render(_ text: String) throws -> OMRTextImage {
            var pixels = [UInt8](repeating: 255, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue,
                ) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 48, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]
                context.setFillColor(gray: 0, alpha: 1)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 20, y: 40)
                CTLineDraw(line, context)
                return true
            }
            try #require(drawn)
            // CGContext's buffer is already row-major with the top row first in memory.
            return OMRTextImage(pixels: pixels, width: width, height: height)
        }

        @Test func readsJapaneseAndLatinTextWithOneBoxPerCharacter() throws {
            let image = try Self.render("あいう abc")
            let lines = try VisionTextRecognizer().recognize(image)

            #expect(lines.contains { $0.text.contains("あいう") })
            let chars = lines.flatMap(\.characters)
            #expect(chars.count >= 6)
            #expect(Set(chars.map { Int($0.x) }).count == chars.count)
            #expect(chars.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 600 && $0.y >= 0 && $0.y + $0.height <= 120 })
            #expect(lines.allSatisfy { $0.width > 0 && $0.height > 0 && $0.y >= 0 && $0.y + $0.height <= 120 })
        }
    }
#endif
