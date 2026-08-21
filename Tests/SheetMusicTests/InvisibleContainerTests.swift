#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicLayout
    import Testing

    struct InvisibleContainerTests {
        @Test func measureDefaultsToEmptyInvisible() {
            let m = LayoutMeasure(
                measureIndex: 0, origin: .zero, width: 10, elements: [],
            )
            #expect(m.invisibleElements.isEmpty)
        }

        @Test func systemDefaultsToEmptyInvisibleSpanners() {
            let s = LayoutSystem(
                origin: .zero,
                size: CGSize(width: 10, height: 10),
                measures: [],
                staffOrigins: [],
                partLabels: [],
                spanners: [],
                sp: 4,
            )
            #expect(s.invisibleSpanners.isEmpty)
        }
    }
#endif
