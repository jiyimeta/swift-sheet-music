import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
    /// with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

@Suite("ScoreHitTester — engraved elements")
struct ScoreHitTesterElementTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("Identity-bearing ink in markers and jumps is hit and highlighted", arguments: [false, true])
    func navigationCollections(isJump: Bool) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Synthetic placement pins collection traversal without assigning identities to navigation marks.
        let element = ElementHitFixtures.bar("double")
        let tester = ScoreHitTester(document: ElementHitFixtures.document(
            [], markers: isJump ? [] : [element], jumps: isJump ? [element] : [],
        ))
        let target = ScoreHitTarget.barLine(measureIndex: 0, role: .explicit)
        let point = CGPoint(x: 133, y: 130)
        #expect(tester.hitTest(at: point) == target)
        #expect(tester.itemID(at: point) == target.selectableItem)
        #expect(tester.elementHitRect(for: target) == CGRect(x: 126.25, y: 110, width: 7.5, height: 40))
        try ElementHitCommandChecks.apply(#require(tester.itemID(at: point)?.elementID))
    }

    @Test("Double barline strokes hit; the empty gap does not")
    func doubleBarlineInk() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let tester = ScoreHitTester(document: ElementHitFixtures.document([ElementHitFixtures.bar("double")]))
        let target = ScoreHitTarget.barLine(measureIndex: 0, role: .explicit)
        // sp = 10, document origin = (30,40) + (20,10) + (80,80) = (130,130).
        // Centers ±3, stroke width 1.5. The skyline's ±2 box misses both strokes.
        #expect(tester.hitTest(at: CGPoint(x: 127, y: 130)) == target)
        #expect(tester.hitTest(at: CGPoint(x: 133, y: 130)) == target)
        #expect(tester.hitTest(at: CGPoint(x: 130, y: 130)) == nil)
        #expect(tester.itemID(at: CGPoint(x: 133, y: 130)) == .element(.barLine(measureIndex: 0, role: .explicit)))
        #expect(try #require(tester.elementHitRect(for: target)) == CGRect(
            x: 126.25, y: 110, width: 7.5, height: 40,
        ))
    }

    @Test("End strokes and repeat dots hit outside the old skyline box")
    func barlineVariants() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let cases: [(String, CGPoint)] = [
            ("normal", CGPoint(x: 130, y: 130)),
            ("end", CGPoint(x: 134, y: 130)),
            ("final", CGPoint(x: 134, y: 130)),
            ("start-repeat", CGPoint(x: 136, y: 125)),
            ("end-repeat", CGPoint(x: 124, y: 135)),
        ]
        for (subtype, point) in cases {
            let tester = ScoreHitTester(document: ElementHitFixtures.document([ElementHitFixtures.bar(subtype)]))
            #expect(tester.hitTest(at: point) == .barLine(measureIndex: 0, role: .explicit))
            #expect(try #require(tester.elementHitRect(for: .barLine(measureIndex: 0, role: .explicit)))
                .contains(point))
        }
    }

    @Test("Earlier text wins over an overlapping barline")
    func textPrecedesElements() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let lyric = LayoutElement.textMark(
            kind: .lyrics(color: nil, verse: 0, anchor: ElementHitFixtures.anchor),
            text: "glo", origin: ElementHitFixtures.origin,
        )
        let tester = ScoreHitTester(document: ElementHitFixtures.document([ElementHitFixtures.bar("normal"), lyric]))
        #expect(tester.hitTest(at: CGPoint(x: 130, y: 130)) == .lyric(anchor: ElementHitFixtures.anchor, verse: 0))
        #expect(tester.itemID(at: CGPoint(x: 130, y: 130)) == nil)
    }

    @Test("Nil identities produce neither hits nor highlight boxes")
    func unaddressed() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let tester = ScoreHitTester(document: ElementHitFixtures.document(
            [ElementHitFixtures.bar("double", measureIndex: nil)],
        ))
        #expect(tester.hitTest(at: CGPoint(x: 133, y: 130)) == nil)
        #expect(tester.hitTest(at: CGPoint(x: 130, y: 130)) == nil)
        #expect(tester.elementHitRect(for: .barLine(measureIndex: 0, role: .explicit)) == nil)
        #expect(tester.elementHitRect(for: .tempo(anchor: ElementHitFixtures.anchor)) == nil)
    }

    @Test("Emitted hidden ink follows the same identity rule as the renderer")
    func emittedHiddenInk() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let tester = ScoreHitTester(document: ElementHitFixtures.document(
            [], invisibleElements: [ElementHitFixtures.bar("double")],
            invisibleSpanners: [ElementHitFixtures.spanner(.hairpinOpen)],
        ))
        let bar = ScoreHitTarget.barLine(measureIndex: 0, role: .explicit)
        #expect(tester.hitTest(at: CGPoint(x: 133, y: 130)) == bar)
        #expect(try #require(tester.elementHitRect(for: bar)).contains(CGPoint(x: 133, y: 130)))
        #expect(tester.hitTest(at: CGPoint(x: 160, y: 120))
            == .spanner(anchor: ElementHitFixtures.anchor, kind: .hairpin))
    }

    @Test("System spanner segments hit in document space and highlights unite every segment")
    func systemSpannerSegments() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let segment = ElementHitFixtures.spanner(.hairpinOpen)
        let first = try #require(ElementHitFixtures.document([], spanners: [segment]).systems.first)
        let doc = LayoutDocument(
            size: CGSize(width: 400, height: 600), systems: [first, first.movedBy(dy: 300)],
            metrics: ElementHitFixtures.metrics,
        )
        let tester = ScoreHitTester(document: doc)
        let target = ScoreHitTarget.spanner(anchor: ElementHitFixtures.anchor, kind: .hairpin)
        // System-local segment: x 80...180, y 80 ±7. System origins: (30,40), (30,340).
        #expect(tester.hitTest(at: CGPoint(x: 160, y: 120)) == target)
        #expect(tester.hitTest(at: CGPoint(x: 160, y: 420)) == target)
        #expect(tester.itemID(at: CGPoint(x: 160, y: 420))
            == .element(.spanner(anchor: ElementHitFixtures.anchor, kind: .hairpin)))
        #expect(try #require(tester.elementHitRect(for: target)) == CGRect(x: 110, y: 113, width: 100, height: 314))
        #expect(tester.hitTest(at: CGPoint(x: 160, y: 270)) == nil)
    }

    @Test("A start-repeat hit feeds the repeat command, preserving its role")
    func repeatCommandAddress() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.barLine(
            subtype: "start-repeat", origin: ElementHitFixtures.origin,
            halfHeight: 20, measureIndex: 0, role: .startRepeat,
        )
        let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
        let point = CGPoint(x: 136, y: 125)
        #expect(tester.hitTest(at: point) == .barLine(measureIndex: 0, role: .startRepeat))
        let item = try #require(tester.itemID(at: point))
        #expect(item == .element(.barLine(measureIndex: 0, role: .startRepeat)))
        try ElementHitCommandChecks.apply(#require(item.elementID))
    }
}
