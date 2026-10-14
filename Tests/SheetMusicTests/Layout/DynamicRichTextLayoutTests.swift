#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// A dynamic with its own text is typeset from its runs — words in the dynamics style, `<sym>` runs as music glyphs at
/// the size its plain glyphs are drawn at — and placed where a plain dynamic stands: from the same X, its first
/// baseline on the plain glyphs' baseline (MuseScore aligns dynamics on the baseline, `Sid::dynamicsAlign`,
/// `engraving/style/styledef.cpp:1119`). A dynamic printing its subtype is laid out exactly as before. The fixture is
/// `own/dynamics.mscx` (bar 1 p, bar 2 "subito p", bar 3 "più ⟨f⟩", bar 4 "dolce", bar 6 "**poco** ⟨mf⟩" and a plain
/// sff on beat 3).
@Suite("Dynamic rich text in layout")
struct DynamicRichTextLayoutTests {
    /// Tests that run `LayoutEngine.layout` use the installed provider, so they assert relations.
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let anchor = LayoutRichText.anchor(for: .dynamic)
    private static let subito = "subito <sym>dynamicPiano</sym>"

    private static func document(
        showsInvisible: Bool = false, _ edit: (inout Score) -> Void = { _ in },
    ) throws -> LayoutDocument {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics"))
        edit(&score)
        return LayoutEngine.layout(
            score: score, options: ScoreViewOptions(showsInvisibleElements: showsInvisible), availableWidth: 1200,
        )
    }

    /// Edits the dynamic that opens 0-based measure `index`.
    private static func editFirstDynamic(of score: inout Score, measure index: Int, _ edit: (inout Dynamic) -> Void) {
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[index].voices[0].elements.updateValue(at: 0) { element in
                    guard case var .dynamic(dynamic) = element else { return }
                    edit(&dynamic)
                    element = .dynamic(dynamic)
                }
            }
        }
    }

    private static func measure(_ document: LayoutDocument, _ index: Int) throws -> LayoutMeasure {
        try #require(document.systems.flatMap(\.measures).first { $0.measureIndex == index })
    }

    /// The dynamics among `measure`'s elements, in order.
    private static func dynamics(_ measure: LayoutMeasure) -> [(text: String, origin: CGPoint, rich: LayoutRichText?)] {
        measure.elements.compactMap { element in
            guard case let .textMark(.dynamic, text, origin, rich) = element else { return nil }
            return (text, origin, rich)
        }
    }

    @Test("a dynamic printing its subtype is the plain glyph element it always was")
    func derivedDynamicIsUnchanged() throws {
        let dynamics = try Self.dynamics(Self.measure(Self.document(), 0))
        try #require(dynamics.count == 1)
        #expect(dynamics[0].text == "p")
        #expect(dynamics[0].rich == nil)
    }

    @Test("its own words are typeset in the dynamics style")
    func wordsInTheDynamicsStyle() throws {
        let document = try Self.document()
        let dynamic = try #require(Self.dynamics(Self.measure(document, 1)).first)
        let rich = try #require(dynamic.rich)
        #expect(dynamic.text == "subito p")
        let runs = rich.lines.flatMap(\.runs)
        #expect(runs.map(\.content) == [.text("subito p")])
        #expect(runs.map(\.font) == [TextInkGeometry.font(for: .dynamics, metrics: document.metrics)])
    }

    @Test("a <sym> run is a music glyph at the size the plain glyphs are drawn at")
    func symbolRunsAreMusicGlyphs() throws {
        let document = try Self.document()
        let rich = try #require(Self.dynamics(Self.measure(document, 2)).first?.rich)
        let runs = rich.lines.flatMap(\.runs)
        #expect(runs.map(\.content) == [.text("più "), .symbol(codepoint: SMuFLCodepoint.dynamicForte)])
        #expect(runs.last?.font == LayoutFont(face: SMuFLFamily.bravura, pointSize: document.metrics.sp * 4))
    }

    @Test("the rule: the first baseline is the plain glyphs' baseline at the same origin")
    func baselineRule() throws {
        let metrics = StaffMetrics(staffSize: 20)
        let dynamic = Dynamic(
            subtype: "p", velocity: 49, text: "subito ", preservedTextMarkup: PreservedTextMarkup(xmlText: Self.subito),
        )
        let origin = CGPoint(x: 10, y: 40)
        let element = LayoutEngine.dynamicElement(dynamic, anchor: nil, origin: origin, metrics: metrics)
        guard case let .textMark(_, text, placed, rich?) = element else {
            Issue.record("a dynamic with its own text carries no runs")
            return
        }
        #expect(text == "subito ")
        let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.sp * 4)
        let baseline = LayoutElementShape.baselineY(font: glyphFont, originY: origin.y, anchor: .leadingCenter)
        let symbol = try #require(rich.positionedRuns(at: placed, anchor: Self.anchor).last)
        #expect(abs(symbol.baseline.y - baseline) < 1e-6)
        #expect(abs((rich.inkRect(at: placed, anchor: Self.anchor)?.minX ?? -1) - origin.x) < 1e-6)
    }

    @Test("in a bar, its glyphs sit on the baseline a plain dynamic's glyphs sit on")
    func richGlyphSharesThePlainBaseline() throws {
        let document = try Self.document()
        let dynamics = try Self.dynamics(Self.measure(document, 5))
        try #require(dynamics.count == 2)
        let rich = try #require(dynamics[0].rich)
        #expect(dynamics[1].rich == nil)
        let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: document.metrics.sp * 4)
        let plainBaseline = LayoutElementShape.baselineY(
            font: glyphFont, originY: dynamics[1].origin.y, anchor: .leadingCenter,
        )
        let symbols = rich.positionedRuns(at: dynamics[0].origin, anchor: Self.anchor).filter { run in
            if case .symbol = run.content { true } else { false }
        }
        try #require(symbols.count == 2)
        #expect(symbols.map { abs($0.baseline.y - plainBaseline) < 1e-6 } == [true, true])
    }

    @Test("it starts where the plain dynamic would, and hairpin snapping finds it at its tick")
    func richStartsWhereThePlainOneDoes() throws {
        let document = try Self.document()
        let richMeasure = try Self.measure(document, 5)
        let plainDocument = try Self.document { score in
            Self.editFirstDynamic(of: &score, measure: 5) { dynamic in
                dynamic.text = nil
                dynamic.preservedTextMarkup = nil
            }
        }
        let rich = try #require(Self.dynamics(richMeasure).first)
        let plain = try #require(Self.dynamics(Self.measure(plainDocument, 5)).first)
        #expect(rich.rich != nil)
        #expect(plain.rich == nil)
        #expect(abs(rich.origin.x - plain.origin.x) < 1e-6)
        #expect(richMeasure.dynamicExtents.map(\.tick) == [0, 960])
    }

    @Test("an other-dynamics marking draws its word, not its subtype's name")
    func otherDynamicDrawsItsWord() throws {
        let dynamic = try #require(Self.dynamics(Self.measure(Self.document(), 3)).first)
        #expect(dynamic.text == "dolce")
        #expect(dynamic.rich?.lines.flatMap(\.runs).map(\.content) == [.text("dolce")])
    }

    @Test("ink and skyline are the runs' — what hit-testing, autoplace and hairpin snapping read")
    func inkAndSkylineAreTheRuns() throws {
        let document = try Self.document()
        let element = try #require(Self.measure(document, 2).elements.first { element in
            if case .textMark(.dynamic, _, _, .some) = element { true } else { false }
        })
        guard case let .textMark(_, _, origin, rich?) = element else {
            Issue.record("bar 3's dynamic carries no runs")
            return
        }
        let ink = try #require(rich.inkRect(at: origin, anchor: Self.anchor))
        #expect(TextInkGeometry.rects(for: element, metrics: document.metrics) == [ink])
        let shape = try #require(LayoutElementShape.shape(for: element, id: 0, xOffset: 0, metrics: document.metrics))
        let box = try #require(shape.rects.first?.rect)
        #expect(box.minX <= ink.minX + 1e-6 && box.maxX >= ink.maxX - 1e-6)
        #expect(box.minY <= ink.minY + 1e-6 && box.maxY >= ink.maxY - 1e-6)
    }

    @Test("a hidden dynamic with its own text is absent from print, and greyed with its runs when shown")
    func hiddenDynamicKeepsItsRuns() throws {
        let hide: (inout Score) -> Void = { score in
            Self.editFirstDynamic(of: &score, measure: 1) { $0.visible = false }
        }
        #expect(try Self.dynamics(Self.measure(Self.document(hide), 1)).isEmpty)
        let shown = try Self.measure(Self.document(showsInvisible: true, hide), 1)
        let parked = shown.invisibleElements.compactMap { element -> LayoutRichText? in
            if case let .textMark(.dynamic, _, _, rich) = element { return rich }
            return nil
        }
        #expect(parked.count == 1)
        #expect(parked.first?.lines.flatMap(\.runs).map(\.content) == [.text("subito p")])
    }
}
