#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// Expression text and stickings: where MuseScore puts them (`styledef.cpp:1128-1146, 1633-1651`) and how an
/// expression snaps to the dynamic on its beat (`TLayout::layoutExpression`).
@Suite("Expression and sticking layout")
struct ExpressionStickingLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures
    private static let dolce = ExpressionText(text: "dolce")

    private static func dynamic(_ subtype: String = "p") -> VoiceElement {
        .dynamic(Dynamic(subtype: subtype, velocity: 49))
    }

    private static func staffTextElement(_ document: LayoutDocument, _ text: String) -> LayoutElement? {
        F.elements(document).first {
            if case let .staffText(shown, _, _, _, _, _, _, _, _) = $0 { shown == text } else { false }
        }
    }

    private static func dynamicElement(_ document: LayoutDocument) -> LayoutElement? {
        F.elements(document).first { if case .textMark(.dynamic, _, _, _) = $0 { true } else { false } }
    }

    private static func bounds(_ element: LayoutElement) -> CGRect? {
        LayoutElementShape.shape(for: element, id: 0, xOffset: 0, metrics: F.metrics)?.bbox
    }

    private static func probe(_ document: LayoutDocument, _ text: String) throws -> F.StaffTextProbe {
        try #require(F.staffTexts(document).first { $0.text == text })
    }

    @Test("expression defaults below the staff, in its own style, and the placement role moves it above")
    func expressionSitsBelowTheStaff() throws {
        var above = ExpressionText(text: "espress.")
        above.elementProperties.placement = .above
        let document = F.layout(F.score([.expression(Self.dolce), .expression(above), F.whole()]))
        let below = try Self.probe(document, "dolce")
        let up = try Self.probe(document, "espress.")
        #expect(below.style == .expression)
        #expect(below.placement?.side == .below)
        #expect(up.placement?.side == .above)
        // Below the bottom line and above the top line are a staff apart at least.
        #expect(below.origin.y - up.origin.y > 4 * F.sp)
    }

    @Test("an expression on a dynamic's beat starts 0.5 sp right of the dynamic")
    func expressionSnapsRightOfItsDynamic() throws {
        let document = F.layout(F.score([Self.dynamic(), .expression(Self.dolce), F.whole()]))
        let dynamicShape = try #require(Self.dynamicElement(document).flatMap(Self.bounds))
        let expressionShape = try #require(Self.staffTextElement(document, "dolce").flatMap(Self.bounds))
        #expect(abs(expressionShape.minX - (dynamicShape.maxX + 0.5 * F.sp)) < 0.01)
    }

    @Test("the gap after an f is 0.2 sp")
    func gapAfterForteIsShorter() throws {
        let document = F.layout(F.score([Self.dynamic("f"), .expression(Self.dolce), F.whole()]))
        let dynamicShape = try #require(Self.dynamicElement(document).flatMap(Self.bounds))
        let expressionShape = try #require(Self.staffTextElement(document, "dolce").flatMap(Self.bounds))
        #expect(abs(expressionShape.minX - (dynamicShape.maxX + 0.2 * F.sp)) < 0.01)
    }

    @Test("snapped, the expression's baseline is the dynamic's (to a quarter space)")
    func expressionSharesTheDynamicBaseline() throws {
        let document = F.layout(F.score([Self.dynamic(), .expression(Self.dolce), F.whole()]))
        let dynamicElement = try #require(Self.dynamicElement(document))
        guard case let .textMark(_, _, dynamicOrigin, _) = dynamicElement else { return }
        let expression = try Self.probe(document, "dolce")
        let font = TextInkGeometry.font(for: .expression, metrics: F.metrics)
        let baseline = TextInkGeometry.baselineOrigin(
            text: "dolce", font: font, origin: expression.origin, anchor: CGPoint(x: 0, y: 1),
        )
        // A plain dynamic hangs by its glyph box's vertical centre (`TextInkGeometry.labelRects`, anchor (0, 0.5)):
        // its baseline is that origin moved by half (ascent − descent) of the 4 sp music font.
        let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: F.metrics.sp * 4)
        let dynamicBaseline = LayoutElementShape.baselineY(
            font: glyphFont, originY: dynamicOrigin.y, anchor: .leadingCenter,
        )
        // The bound is a quarter space; an UNsnapped expression sits about half a space higher (its default baseline is
        // 2.5 sp under the staff; a plain dynamic's glyph centre hangs 2 sp under it, so its baseline is lower).
        #expect(abs(baseline.y - dynamicBaseline) < 0.25 * F.sp)
    }

    @Test("snapToDynamics off keeps the x snap but the expression keeps its own baseline")
    func snapToDynamicsOffKeepsItsBaseline() throws {
        var free = Self.dolce
        free.snapToDynamics = false
        let snapped = F.layout(F.score([Self.dynamic(), .expression(Self.dolce), F.whole()]))
        let unsnapped = F.layout(F.score([Self.dynamic(), .expression(free), F.whole()]))
        let alone = F.layout(F.score([.expression(Self.dolce), F.whole()]))
        let a = try Self.probe(snapped, "dolce")
        let b = try Self.probe(unsnapped, "dolce")
        #expect(abs(a.origin.x - b.origin.x) < 0.001)
        // Its own baseline is the one it has with no dynamic at all, and not the snapped pair's.
        #expect(try abs(b.origin.y - (Self.probe(alone, "dolce").origin.y)) < 0.001)
        #expect(abs(b.origin.y - a.origin.y) > 0.25 * F.sp)
    }

    @Test("a snapped expression is not pushed off its dynamic's line, even 0.2 sp after an f")
    func snappedExpressionIgnoresItsDynamic() throws {
        for subtype in ["p", "f"] {
            let document = F.layout(F.score([Self.dynamic(subtype), .expression(Self.dolce), F.whole()]))
            let dynamicShape = try #require(Self.dynamicElement(document).flatMap(Self.bounds))
            let expressionShape = try #require(Self.staffTextElement(document, "dolce").flatMap(Self.bounds))
            #expect(expressionShape.minY < dynamicShape.maxY, "\(subtype): the expression shares the dynamic's line")
        }
    }

    @Test("an expression above the staff, or with autoplace off, does not snap")
    func snapOnlyWhenBothAreBelow() throws {
        var above = Self.dolce
        above.elementProperties.placement = .above
        var off = Self.dolce
        off.elementProperties.autoplace = false
        let plain = F.layout(F.score([.expression(Self.dolce), F.whole()]))
        let baseX = try Self.probe(plain, "dolce").origin.x
        for variant in [above, off] {
            let document = F.layout(F.score([Self.dynamic(), .expression(variant), F.whole()]))
            #expect(try abs(Self.probe(document, "dolce").origin.x - baseX) < 0.001)
        }
        // And with no dynamic at all the expression stands where a staff text of the same beat stands.
        let staffText = StaffText(text: "dolce")
        let withText = F.layout(F.score(
            [F.whole()],
            system: [PositionedSystemElement(
                position: .start, element: .staffText(staffText), originalStaff: F.address,
            )],
        ))
        #expect(try abs(Self.probe(withText, "dolce").origin.x - baseX) < 0.001)
    }

    @Test("a sticking is centered on its notehead, below by default, above when asked")
    func stickingPlacement() throws {
        var up = Sticking(text: "L")
        up.elementProperties.placement = .above
        let document = F.layout(F.score([.sticking(Sticking(text: "R")), .sticking(up), F.whole()]))
        let noteX = try #require(F.chordNoteX(document))
        let r = try Self.probe(document, "R")
        let l = try Self.probe(document, "L")
        #expect(r.style == .sticking)
        #expect(r.placement?.side == .below)
        #expect(l.placement?.side == .above)
        let center = try #require(Self.staffTextElement(document, "R").flatMap(Self.bounds)).midX
        #expect(abs(center - noteX) < 0.5)
    }

    @Test("a hidden expression draws nothing unless invisible elements are shown, then it is a ghost")
    func hiddenExpression() {
        var hidden = ExpressionText(text: "unseen")
        hidden.visible = false
        let score = F.score([.expression(hidden), F.whole()])
        let plain = F.layout(score)
        #expect(F.staffTexts(plain).isEmpty)
        let shown = F.layout(score, showsInvisible: true)
        let ghosts = shown.systems.flatMap(\.measures).flatMap(\.invisibleElements)
        #expect(ghosts.count { if case .staffText = $0 { true } else { false } } == 1)
    }

    @Test("a font override in the unmodeled children reaches the text")
    func fontOverrideReachesText() throws {
        var big = ExpressionText(text: "dolce")
        big.preservedMarkup = [PreservedXML(name: "size", text: "14")]
        let document = F.layout(F.score([.expression(big), F.whole()]))
        let element = try #require(Self.staffTextElement(document, "dolce"))
        guard case let .staffText(_, _, _, _, _, _, properties, _, _) = element else { return }
        #expect(properties.size == 14)
        #expect(big.preservedMarkup.count == 1)
    }

    @Test("MuseScore's own bars: four expressions, two stickings, the hidden one a ghost")
    func fixtureBars() throws {
        let document = try F.layout(F.load("w5-annotation-text"))
        let texts = F.staffTexts(document)
        #expect(texts.map(\.text).sorted() == ["L", "R", "con brio", "dolce", "espress."])
        let brio = try #require(texts.first { $0.text == "con brio" })
        #expect(brio.richText?.lines.first?.runs.count == 2)
    }
}
