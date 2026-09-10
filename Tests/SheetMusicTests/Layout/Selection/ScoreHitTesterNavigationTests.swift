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

@Suite("Navigation hits share installed text and glyph metrics")
struct ScoreHitTesterNavigationTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("Jump text keeps shipped padding and unpadded highlights", arguments: ["D.S.", "", "   ", "D.S.\nFine"])
    func jumpText(_ text: String) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.jump(
            text: text, origin: ElementHitFixtures.origin,
            identity: .jump(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 1),
        )
        try checkText(element, rendered: text)
    }

    @Test("Text marker variants measure the renderer's label", arguments: [
        Marker.Kind.fine, .toCoda, .daCapo, .dalSegno, .other,
    ])
    func markerText(_ kind: Marker.Kind) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let label: String
        switch kind {
        case .fine: label = "Fine"
        case .toCoda: label = "To Coda"
        case .daCapo: label = "D.C."
        case .dalSegno: label = "D.S."
        default: label = "custom marker"
        }
        let element = Self.marker(kind, text: kind == .other ? label : "")
        try checkText(element, rendered: label)
    }

    @Test("Every glyph marker uses centered glyph ink, never its label rectangle", arguments: [
        Marker.Kind.segno, .varsegno, .coda, .varcoda, .codetta, .toCodaSym,
    ])
    func glyphMarkers(_ kind: Marker.Kind) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Deliberately long metadata label: glyph variants do not draw this text.
        let element = Self.marker(kind, text: String(repeating: "W", count: 64))
        let tester = ScoreHitTester(document: ElementHitFixtures.document([], markers: [element]))
        let codepoint = kind == .segno || kind == .varsegno ? SMuFLCodepoint.segno : SMuFLCodepoint.coda
        let raw = tester.glyphInkRects([(codepoint, ElementHitFixtures.origin)])
        let glyph = try #require(raw.first)
        try #require(glyph.width > 0 && glyph.height > 0)
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 40)
        let provider = FontMetrics.provider
        let ink = try #require(provider.glyphPathBoundingBox(font: font, codepoint: UInt16(codepoint)))
        // Centered X ignores the bearing; top converts Y-up maxY using the baseline offset.
        #expect(glyph == CGRect(
            x: 80 - ink.width / 2,
            y: 80 + (provider.ascent(font: font) - provider.descent(font: font)) / 2 - ink.maxY,
            width: ink.width, height: ink.height,
        ))
        let boxes = raw.map { $0.offsetBy(dx: 50, dy: 50) }
        let box = glyph.offsetBy(dx: 50, dy: 50)
        let target = try ScoreHitTarget(elementID: #require(element.elementID))
        let hit = CGPoint(x: box.midX, y: box.midY)
        #expect(box.contains(hit))
        #expect(tester.hitTest(at: hit) == target)
        #expect(tester.elementHitRect(for: target) == box)
        #expect(tester.hitTest(at: hit)?.selectableItem == element.elementItemID)
        let shapeKind = try #require(LayoutElementShape.kind(of: element))
        let fallback = try #require(LayoutElementShape.autoplacedRects(
            for: element, kind: shapeKind, metrics: ElementHitFixtures.metrics,
        ).first).offsetBy(dx: 50, dy: 50)
        let candidates = (1 ... 99).map {
            CGPoint(x: fallback.minX + fallback.width * CGFloat($0) / 100, y: fallback.midY)
        }
        let miss = try #require(candidates.first { point in
            fallback.contains(point) && boxes.allSatisfy { !$0.contains(point) }
        })
        // Liveness guards: the miss would be a false hit if marker text fallback were used.
        #expect(fallback.contains(miss))
        #expect(boxes.allSatisfy { !$0.contains(miss) })
        #expect(tester.hitTest(at: miss) == nil)
    }

    @Test("Separated entries retain their indices and text still precedes navigation")
    func navigationOrder() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let first = Self.marker(.other, text: "Fine")
        let second = LayoutElement.marker(
            kind: .other, text: "Fine", origin: CGPoint(x: 500, y: 80),
            identity: .marker(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 1),
        )
        let tester = ScoreHitTester(document: ElementHitFixtures.document([], markers: [first, second]))
        for element in [first, second] {
            let target = try ScoreHitTarget(elementID: #require(element.elementID))
            let box = try #require(tester.elementHitRect(for: target))
            try #require(box.width > 0 && box.height > 0)
            #expect(tester.hitTest(at: CGPoint(x: box.midX, y: box.midY)) == target)
        }
        // Synthetic marker/jump overlap checks collection priority, not same-list engraving defects.
        let jump = LayoutElement.jump(
            text: "Fine", origin: ElementHitFixtures.origin,
            identity: .jump(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 0),
        )
        let overlap = ScoreHitTester(document: ElementHitFixtures.document([], markers: [first], jumps: [jump]))
        let target = try ScoreHitTarget(elementID: #require(first.elementID))
        let box = try #require(overlap.elementHitRect(for: target))
        let point = CGPoint(x: box.midX, y: box.midY)
        #expect(try #require(overlap.elementHitRect(for: .jump(
            staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 0,
        ))).contains(point))
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
        #expect(textBox.contains(sharedPoint) && box.contains(sharedPoint))
        #expect(withText.hitElement(at: sharedPoint) == target)
        #expect(withText.hitTest(at: sharedPoint) == textTarget)
    }

    @available(macOS 15.0, iOS 16.0, *)
    private func checkText(_ element: LayoutElement, rendered: String) throws {
        let isJump = if case .jump = element { true } else { false }
        let tester = ScoreHitTester(document: ElementHitFixtures.document(
            [], markers: isJump ? [] : [element], jumps: isJump ? [element] : [],
        ))
        let measured: LayoutElement
        if case let .marker(kind, _, origin, identity) = element {
            measured = .marker(kind: kind, text: rendered, origin: origin, identity: identity)
        } else {
            measured = element
        }
        let kind = try #require(LayoutElementShape.kind(of: measured))
        let raw = try #require(LayoutElementShape.autoplacedRects(
            for: measured, kind: kind, metrics: ElementHitFixtures.metrics,
        ).first)
        // NotationTextStyle uses 2.5 sp = 25 points for both navigation text roles.
        let font = LayoutFont(face: "Edwin", pointSize: 25)
        let provider = FontMetrics.provider
        let lines = rendered.components(separatedBy: "\n")
        let width = lines.map { provider.typographicWidth(text: $0, font: font) }.max() ?? 0
        let lineHeight = provider.ascent(font: font) + provider.descent(font: font)
        let height = lineHeight + CGFloat(lines.count - 1) * (lineHeight + provider.leading(font: font))
        // The renderer centers the whole multiline block, including each line's leading.
        #expect(raw == CGRect(x: 80, y: 80 - height / 2, width: width, height: height))
        let box = raw.offsetBy(dx: 50, dy: 50)
        let padded = box.insetBy(dx: -2.5, dy: -2.5) // sp=10, tolerance=0.25.
        let target = try ScoreHitTarget(elementID: #require(element.elementID))
        #expect(tester.elementHitRect(for: target) == box)
        let hit = CGPoint(x: padded.midX, y: padded.midY)
        #expect(padded.contains(hit))
        #expect(tester.hitTest(at: hit) == target)
        #expect(tester.hitTest(at: hit)?.selectableItem == element.elementItemID)
        let edgeHit = CGPoint(x: box.minX - 2.4, y: box.midY)
        #expect(padded.contains(edgeHit))
        #expect(!box.contains(edgeHit))
        #expect(tester.hitTest(at: edgeHit) == target)
        for miss in [
            CGPoint(x: box.minX - 2.6, y: box.midY),
            CGPoint(x: box.minX - 5.5, y: box.midY), // 0.3 sp outside the padded edge.
        ] {
            // Move the mark's left edge onto this SAME query point, even for zero-width text.
            let dx = box.minX - miss.x
            let shifted: LayoutElement
            switch element {
            case let .jump(text, origin, identity):
                shifted = .jump(text: text, origin: CGPoint(x: origin.x - dx, y: origin.y), identity: identity)
            case let .marker(kind, text, origin, identity):
                shifted = .marker(
                    kind: kind, text: text, origin: CGPoint(x: origin.x - dx, y: origin.y), identity: identity,
                )
            default:
                Issue.record("expected navigation text"); return
            }
            let control = ScoreHitTester(document: ElementHitFixtures.document(
                [], markers: isJump ? [] : [shifted], jumps: isJump ? [shifted] : [],
            ))
            #expect(!padded.contains(miss))
            #expect(padded.offsetBy(dx: -dx, dy: 0).contains(miss))
            #expect(control.hitTest(at: miss) == target)
            #expect(tester.hitTest(at: miss) == nil)
        }
    }

    private static func marker(_ kind: Marker.Kind, text: String) -> LayoutElement {
        .marker(
            kind: kind, text: text, origin: ElementHitFixtures.origin,
            identity: .marker(staff: ElementHitFixtures.anchor.staff, measureIndex: 0, index: 0),
        )
    }
}
