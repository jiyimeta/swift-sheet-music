import SheetMusicLayout
import Testing

#if canImport(CoreText)
    import CoreText
    import Foundation
    import SheetMusicLayoutApple
#endif

struct TextSelectionOffsetsTests {
    @Test func portableSelectionClampsAndPreservesEmptyRanges() {
        let provider = StubFontMetricsProvider()
        let font = LayoutFont(face: "", pointSize: 20)
        #expect(provider.selectionOffsets(text: "abc", font: font, range: 1 ..< 1).isEmpty)
        #expect(provider.selectionOffsets(text: "abc", font: font, range: 8 ..< 9).isEmpty)
        #expect(provider.selectionOffsets(text: "", font: font, range: 0 ..< 3).isEmpty)
        let offsets = provider.caretOffsets(text: "abc", font: font)
        #expect(provider.selectionOffsets(text: "abc", font: font, range: -2 ..< 8) == [offsets[0] ... offsets[3]])
    }

    #if canImport(CoreText)
        @available(macOS 15.0, *)
        @Test func mixedDirectionSelectionDoesNotCoverUnselectedHebrew() throws {
            let text = "abc אבג def"
            let font = LayoutFont(face: "Helvetica", pointSize: 24)
            let provider = AppleFontMetricsProvider()
            let fragments = provider.selectionOffsets(text: text, font: font, range: 2 ..< 5)
            let line = makeLine(text: text, size: font.pointSize)
            #expect(fragments.count == 2)
            for index in [2, 3, 4] {
                let center = try #require(glyphCenter(at: index, line: line))
                #expect(fragments.contains { $0.contains(center) })
            }
            for index in [0, 1, 5, 6, 8, 9, 10] {
                let center = try #require(glyphCenter(at: index, line: line))
                #expect(!fragments.contains { $0.contains(center) })
            }
        }

        @available(macOS 15.0, *)
        @Test func fullMixedDirectionSelectionMergesAdjacentRuns() throws {
            let text = "abc אבג def"
            let font = LayoutFont(face: "Helvetica", pointSize: 24)
            let provider = AppleFontMetricsProvider()
            let fragments = provider.selectionOffsets(text: text, font: font, range: 0 ..< text.utf16.count)
            let fragment = try #require(fragments.first)
            #expect(fragments.count == 1)
            #expect(abs(fragment.lowerBound) < 0.001)
            #expect(abs(fragment.upperBound - provider.typographicWidth(text: text, font: font)) < 0.001)
        }

        @available(macOS 15.0, *)
        @Test func selectingTheFirstLogicalRTLCharacterUsesTheRunsRightEdge() throws {
            let text = "אבג"
            let font = LayoutFont(face: "Helvetica", pointSize: 24)
            let fragments = AppleFontMetricsProvider().selectionOffsets(text: text, font: font, range: 0 ..< 1)
            let line = makeLine(text: text, size: font.pointSize)
            let selected = try #require(glyphCenter(at: 0, line: line))
            let unselected = try #require(glyphCenter(at: 1, line: line))
            #expect(fragments.contains { $0.contains(selected) })
            #expect(!fragments.contains { $0.contains(unselected) })
        }

        private func makeLine(text: String, size: CGFloat) -> CTLine {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            return CTLineCreateWithAttributedString(string as CFAttributedString)
        }

        private func glyphCenter(at index: Int, line: CTLine) -> CGFloat? {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                var indices = [CFIndex](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                let all = CFRange(location: 0, length: 0)
                CTRunGetStringIndices(run, all, &indices)
                CTRunGetPositions(run, all, &positions)
                CTRunGetAdvances(run, all, &advances)
                if let glyph = indices.firstIndex(of: index) {
                    return positions[glyph].x + advances[glyph].width / 2
                }
            }
            return nil
        }
    #endif
}
