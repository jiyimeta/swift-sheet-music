#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// A marker or jump is hit where its runs are: the box the skyline reserves for them, padded by text's reach — a segno
/// included, a symbol run of its marker's text. A mark without runs draws nothing and is never hit.
@Suite("Navigation hits are their runs' box")
struct ScoreHitTesterNavigationTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func marker(
        _ kind: Marker.Kind, text: String? = nil, index: Int = 0, origin: CGPoint = ElementHitFixtures.origin,
    ) -> LayoutElement {
        let xmlText = text ?? kind.defaultXMLText
        return .marker(
            kind: kind, text: RichText(xmlText: xmlText).plainText, origin: origin,
            identity: .marker(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: index),
            richText: ElementHitFixtures.navigationText(
                xmlText, style: kind.isRightMarker ? .repeatRight : .repeatLeft, marker: true,
            ),
        )
    }

    private static func jump(_ text: String, origin: CGPoint = ElementHitFixtures.origin) -> LayoutElement {
        .jump(
            text: text, origin: origin,
            identity: .jump(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 0),
            richText: ElementHitFixtures.navigationText(text, style: .repeatRight),
        )
    }

    @Test("every marker kind is highlighted by its runs' box and hit within text's reach", arguments: [
        Marker.Kind.segno, .varsegno, .coda, .varcoda, .codetta, .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda,
    ])
    func markerHit(_ kind: Marker.Kind) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        try Self.checkHit(Self.marker(kind), isJump: false)
    }

    /// An empty jump keeps the zero-width, line-high box it always had, so it can still be selected and deleted.
    @Test(
        "a jump is highlighted by its runs' box and hit within text's reach",
        arguments: ["D.S.", "", "D.S.\nal Fine"],
    )
    func jumpHit(_ text: String) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        try Self.checkHit(Self.jump(text), isJump: true)
    }

    @Test("a marker without runs is never hit")
    func noRunsNoHit() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let marker = LayoutElement.marker(
            kind: .fine, text: "Fine", origin: ElementHitFixtures.origin,
            identity: .marker(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 0),
        )
        let tester = ScoreHitTester(document: ElementHitFixtures.document([], markers: [marker]))
        let target = try ScoreHitTarget(elementID: #require(marker.elementID))
        #expect(tester.elementHitRect(for: target) == nil)
        #expect(tester.hitTest(at: CGPoint(x: 130, y: 130)) == nil)
    }

    @Test("Separated entries retain their indices and text still precedes navigation")
    func navigationOrder() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let first = Self.marker(.user, text: "Fine")
        let second = Self.marker(.user, text: "Fine", index: 1, origin: CGPoint(x: 500, y: 80))
        let tester = ScoreHitTester(document: ElementHitFixtures.document([], markers: [first, second]))
        for element in [first, second] {
            let target = try ScoreHitTarget(elementID: #require(element.elementID))
            let box = try #require(tester.elementHitRect(for: target))
            try #require(box.width > 0 && box.height > 0)
            #expect(tester.hitTest(at: CGPoint(x: box.midX, y: box.midY)) == target)
        }
        // A jump laid over the first marker, whatever the jump anchor: its block's left edge on the marker's.
        let local = try #require(LayoutElementShape.navigationLabelRect(for: first))
        let jumpRuns = ElementHitFixtures.navigationText("Fine", style: .repeatRight)
        let jumpWidth = jumpRuns.ink?.width ?? 0
        let jump = Self.jump("Fine", origin: CGPoint(
            x: local.minX + LayoutRichText.anchor(for: .jump).x * jumpWidth, y: ElementHitFixtures.origin.y,
        ))
        let overlap = ScoreHitTester(document: ElementHitFixtures.document([], markers: [first], jumps: [jump]))
        let target = try ScoreHitTarget(elementID: #require(first.elementID))
        let box = try #require(overlap.elementHitRect(for: target))
        let point = CGPoint(x: box.midX, y: box.midY)
        let jumpBox = try #require(overlap.elementHitRect(for: .jump(
            staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 0,
        )))
        #expect(jumpBox.contains(point))
        #expect(overlap.hitTest(at: point) == target)
        let text = LayoutElement.staffText(
            text: "Fine", origin: ElementHitFixtures.origin, color: nil,
            style: .staffText, anchor: ElementHitFixtures.anchor,
        )
        let withText = ScoreHitTester(document: ElementHitFixtures.document([text], markers: [first]))
        let textTarget = ScoreHitTarget.staffText(anchor: ElementHitFixtures.anchor, style: .staffText)
        let textBox = try #require(withText.textHitRect(for: textTarget))
        let left = max(textBox.minX, box.minX)
        let right = min(textBox.maxX, box.maxX)
        let top = max(textBox.minY, box.minY)
        let bottom = min(textBox.maxY, box.maxY)
        try #require(right > left && bottom > top)
        let sharedPoint = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
        #expect(withText.hitElement(at: sharedPoint) == target)
        #expect(withText.hitTest(at: sharedPoint) == textTarget)
    }

    /// The element's runs' box, at the fixture document's measure offset (30, 40) + (20, 10), is its highlight; a click
    /// inside text's reach of it hits it, one beyond misses.
    @available(macOS 15.0, iOS 16.0, *)
    private static func checkHit(_ element: LayoutElement, isJump: Bool) throws {
        let tester = ScoreHitTester(document: ElementHitFixtures.document(
            [], markers: isJump ? [] : [element], jumps: isJump ? [element] : [],
        ))
        let local = try #require(LayoutElementShape.navigationLabelRect(for: element))
        let box = local.offsetBy(dx: 50, dy: 50)
        let target = try ScoreHitTarget(elementID: #require(element.elementID))
        #expect(tester.elementHitRect(for: target) == box)
        let center = CGPoint(x: box.midX, y: box.midY)
        #expect(tester.hitTest(at: center) == target)
        #expect(tester.hitTest(at: center)?.selectableItem == element.elementItemID)
        let reach = ElementHitFixtures.metrics.sp * ScoreHitTester.textHitTolerance
        #expect(tester.hitTest(at: CGPoint(x: box.minX - reach * 0.9, y: box.midY)) == target)
        #expect(tester.hitTest(at: CGPoint(x: box.minX - reach * 1.1, y: box.midY)) == nil)
    }
}
