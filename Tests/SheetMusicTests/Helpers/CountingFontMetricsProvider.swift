// Apple-only because its one user is: the drawing it lets a test probe is the CALayer builder's.
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import SheetMusicLayout

    /// Forwards every requirement to `base` and counts the calls, so a test can tell whether a computation — a layout,
    /// a layer build — read the provider it was scoped to (`FontMetrics.withProvider`).
    final class CountingFontMetricsProvider: FontMetricsProvider, @unchecked Sendable {
        private let base: any FontMetricsProvider
        /// Guards `calls`: a computation may measure from more than one thread.
        private let lock = NSLock()
        private var calls = 0

        init(base: any FontMetricsProvider) {
            self.base = base
        }

        /// How many requirements were called so far.
        var reads: Int {
            lock.withLock { calls }
        }

        private func counted<Answer>(_ answer: () -> Answer) -> Answer {
            lock.withLock { calls += 1 }
            return answer()
        }

        func ascent(font: LayoutFont) -> CGFloat {
            counted { base.ascent(font: font) }
        }

        func descent(font: LayoutFont) -> CGFloat {
            counted { base.descent(font: font) }
        }

        func leading(font: LayoutFont) -> CGFloat {
            counted { base.leading(font: font) }
        }

        func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> CGRect? {
            counted { base.glyphPathBoundingBox(font: font, codepoint: codepoint) }
        }

        func typographicWidth(text: String, font: LayoutFont) -> CGFloat {
            counted { base.typographicWidth(text: text, font: font) }
        }

        func caretOffsets(text: String, font: LayoutFont) -> [CGFloat] {
            counted { base.caretOffsets(text: text, font: font) }
        }

        func selectionOffsets(text: String, font: LayoutFont, range: Range<Int>) -> [ClosedRange<CGFloat>] {
            counted { base.selectionOffsets(text: text, font: font, range: range) }
        }

        func characterIndex(forOffset offset: CGFloat, text: String, font: LayoutFont) -> Int {
            counted { base.characterIndex(forOffset: offset, text: text, font: font) }
        }

        func inkBounds(text: String, font: LayoutFont) -> InkBounds {
            counted { base.inkBounds(text: text, font: font) }
        }

        func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
            counted { base.textInkBounds(text: text, font: font) }
        }

        func renderingTextFont(_ font: LayoutFont) -> LayoutFont {
            counted { base.renderingTextFont(font) }
        }
    }
#endif
