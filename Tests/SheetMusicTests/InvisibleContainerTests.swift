import Foundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's CoreGraphics shims also export `CGSize`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGSize` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

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
