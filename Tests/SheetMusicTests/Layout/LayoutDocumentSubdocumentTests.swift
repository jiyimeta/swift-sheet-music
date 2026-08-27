import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's CoreGraphics shims also export `CGFloat`,
    /// `CGPoint`, `CGSize` (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so
    /// anchor explicitly to SheetMusicLayout's own definitions instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

@Suite("LayoutDocument.subdocument")
struct LayoutDocumentSubdocumentTests {
    // MARK: - Helpers

    /// Constructs a lightweight `LayoutSystem` stub whose bottom edge in
    /// document coordinates is `originY + height`.
    private func makeSystem(originY: CGFloat, height: CGFloat) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(x: 0, y: originY),
            size: CGSize(width: 100, height: height),
            measures: [],
            staffOrigins: [],
            partLabels: [],
            spanners: [],
            sp: 7,
        )
    }

    private func makeDocument() -> LayoutDocument {
        LayoutDocument(
            size: CGSize(width: 100, height: 320),
            systems: [
                makeSystem(originY: 0, height: 100),
                makeSystem(originY: 120, height: 100),
                makeSystem(originY: 240, height: 100),
            ],
            metrics: StaffMetrics(staffSize: 28),
        )
    }

    // MARK: - Slice count + origin shift

    /// Slicing a middle page lifts its first system's origin.y to ~0 and
    /// returns exactly the systems in the range.
    @Test func sliceCountAndOriginShift() {
        let doc = makeDocument()
        // Page starting at system 1 (doc-Y 120). Lift by -120.
        let sub = doc.subdocument(systems: 1 ..< 3, yOffset: -120)

        #expect(sub.systems.count == 2)
        #expect(abs(sub.systems[0].origin.y - 0) < 0.0001)
        // Second system was at 240; shifted by -120 → 120.
        #expect(abs(sub.systems[1].origin.y - 120) < 0.0001)
        // Content bound is the last system's shifted bottom: 120 + 100 = 220.
        #expect(abs(sub.size.height - 220) < 0.0001)
        // Width is carried unchanged; title frame is dropped.
        #expect(sub.size.width == doc.size.width)
        #expect(sub.titleFrame == nil)
    }

    /// The first page (yOffset 0) keeps document-absolute origins.
    @Test func firstPageKeepsOrigins() {
        let doc = makeDocument()
        let sub = doc.subdocument(systems: 0 ..< 1, yOffset: 0)

        #expect(sub.systems.count == 1)
        #expect(abs(sub.systems[0].origin.y - 0) < 0.0001)
        #expect(abs(sub.size.height - 100) < 0.0001)
    }
}
