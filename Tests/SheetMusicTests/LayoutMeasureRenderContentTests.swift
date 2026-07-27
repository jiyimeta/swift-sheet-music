#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutMeasureRenderContent")
    struct LayoutMeasureRenderContentTests {
        private func measure(
            x: CGFloat, y: CGFloat = 0, barlineX: CGFloat = 10,
        ) -> LayoutMeasure {
            LayoutMeasure(
                measureIndex: 3,
                origin: CGPoint(x: x, y: y),
                width: 40,
                elements: [
                    .barLine(subtype: nil, origin: CGPoint(x: barlineX, y: 5)),
                ],
            )
        }

        @Test("an origin.x-only shift preserves render content")
        func xShiftIsSameContent() {
            #expect(measure(x: 0).hasSameRenderContent(as: measure(x: 120)))
        }

        @Test("an origin.y shift is a content change")
        func yShiftIsDifferent() {
            #expect(
                !measure(x: 0, y: 0)
                    .hasSameRenderContent(as: measure(x: 0, y: 7)),
            )
        }

        @Test("a drawn element change is a content change")
        func elementChangeIsDifferent() {
            #expect(
                !measure(x: 0, barlineX: 10)
                    .hasSameRenderContent(as: measure(x: 0, barlineX: 11)),
            )
        }

        @Test("a width change is a content change")
        func widthChangeIsDifferent() {
            let a = measure(x: 0)
            let b = LayoutMeasure(
                measureIndex: 3,
                origin: CGPoint(x: 0, y: 0),
                width: 41,
                elements: a.elements,
            )
            #expect(!a.hasSameRenderContent(as: b))
        }
    }
#endif
