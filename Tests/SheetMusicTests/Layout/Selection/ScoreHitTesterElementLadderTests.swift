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

@Suite("Element hits preserve the priority ladder")
struct ScoreHitTesterElementLadderTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private struct Rung {
        let elements: [LayoutElement]
        let point: CGPoint
        let target: ScoreHitTarget
    }

    private static var rungs: [Rung] {
        let anchor = ElementHitFixtures.anchor
        let note = ElementHitFixtures.noteID
        let rest = RestID(staff: anchor.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let tuplet = TupletID(staff: anchor.staff, measureIndex: 0, voiceIndex: 0, startElementIndex: 1)
        let origin = ElementHitFixtures.origin
        return [
            Rung(elements: [ElementHitFixtures.chord()], point: origin, target: .note(note)),
            Rung(elements: [.rest(
                duration: .quarter,
                origin: origin,
                voiceIndex: 0,
                restID: rest,
                hasLegerLine: false,
            )], point: origin, target: .rest(rest)),
            Rung(elements: [ElementHitFixtures.chord(.eighth, beamed: true), .beam(
                fromOrigin: CGPoint(x: 85.9, y: 45), toOrigin: CGPoint(x: 150, y: 45), direction: .up, level: 1,
            )], point: CGPoint(x: 100, y: 45), target: .beam(notes: [note])),
            Rung(
                elements: [ElementHitFixtures.chord(.eighth)],
                point: CGPoint(x: 90, y: 50),
                target: .flag(notes: [note]),
            ),
            Rung(
                elements: [ElementHitFixtures.chord()],
                point: CGPoint(x: 85.9, y: 60),
                target: .stem(notes: [note]),
            ),
            Rung(elements: [.tupletLabel(
                fromOrigin: CGPoint(x: 60, y: 80), toOrigin: CGPoint(x: 140, y: 80),
                text: "3", hasBracket: true, isAbove: true, tupletID: tuplet,
            )], point: CGPoint(x: 100, y: 80), target: .tuplet(tuplet)),
            Rung(
                elements: [.clef(rawType: "G", origin: origin, anchor: .explicit(anchor))],
                point: CGPoint(x: 80, y: 90),
                target: .clef(.explicit(anchor)),
            ),
            Rung(
                elements: [.textMark(kind: .lyrics(verse: 0, anchor: anchor), text: "glo", origin: origin)],
                point: origin,
                target: .lyric(anchor: anchor, verse: 0),
            ),
        ]
    }

    @Test("Every existing rung beats an overlapping element, regardless of element emission order")
    func earlierRungsWin() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        for rung in Self.rungs {
            let point = CGPoint(x: rung.point.x + 50, y: rung.point.y + 50)
            let baseline = ScoreHitTester(document: ElementHitFixtures.document(rung.elements))
            #expect(baseline.hitTest(at: point) == rung.target)
            let bar = LayoutElement.barLine(
                subtype: "normal", origin: rung.point, halfHeight: 20, measureIndex: 0, role: .trailing,
            )
            for elements in [[bar] + rung.elements, rung.elements + [bar]] {
                let tester = ScoreHitTester(document: ElementHitFixtures.document(elements))
                #expect(tester.hitElement(at: point) == .barLine(measureIndex: 0, role: .trailing))
                #expect(tester.hitTest(at: point) == rung.target)
                #expect(tester.itemID(at: point) == baseline.itemID(at: point))
            }
        }
    }

    @Test("An articulation cannot take a notehead's click")
    func notePrecedesArticulation() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let anchor = ElementHitFixtures.anchor
        let articulation = LayoutElement.articulation(
            kind: .accent, origin: ElementHitFixtures.origin, isAbove: true, anchor: anchor,
        )
        let tester = ScoreHitTester(document: ElementHitFixtures.document([articulation, ElementHitFixtures.chord()]))
        let target = ScoreHitTarget.articulation(anchor: anchor, kind: .accent)
        let box = try #require(tester.elementHitRect(for: target))
        let point = CGPoint(x: box.midX, y: box.midY)
        let dx = point.x - 130
        let dy = point.y - 130
        #expect(dx * dx + dy * dy < 144, "fixture must overlap the 12-point notehead hit circle")
        #expect(tester.hitElement(at: point) == target)
        #expect(tester.hitTest(at: point) == .note(ElementHitFixtures.noteID))
    }

    @Test("An earlier measure's spilling element cannot steal a later measure's note")
    func crossMeasureOverlap() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let bar = LayoutElement.barLine(
            subtype: "normal", origin: CGPoint(x: 180, y: 80), halfHeight: 20, measureIndex: 0, role: .trailing,
        )
        let system = LayoutSystem(
            origin: .zero, size: CGSize(width: 400, height: 200),
            measures: [
                LayoutMeasure(measureIndex: 0, origin: .zero, width: 170, elements: [bar]),
                LayoutMeasure(
                    measureIndex: 1,
                    origin: CGPoint(x: 100, y: 0),
                    width: 200,
                    elements: [ElementHitFixtures.chord()],
                ),
            ], staffOrigins: [], partLabels: [], spanners: [], sp: 10,
        )
        let tester = ScoreHitTester(document: LayoutDocument(
            size: system.size, systems: [system], metrics: ElementHitFixtures.metrics,
        ))
        let point = CGPoint(x: 180, y: 80)
        #expect(tester.hitElement(at: point) == .barLine(measureIndex: 0, role: .trailing))
        #expect(tester.hitTest(at: point) == .note(ElementHitFixtures.noteID))
    }

    @Test("Overlapping new kinds resolve in emission order")
    func elementOrder() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let bar = ElementHitFixtures.bar("normal")
        let hairpin = ElementHitFixtures.spanner(.hairpinOpen)
        let point = CGPoint(x: 130, y: 130)
        #expect(ScoreHitTester(document: ElementHitFixtures.document([bar, hairpin])).hitTest(at: point)
            == .barLine(measureIndex: 0, role: .explicit))
        #expect(ScoreHitTester(document: ElementHitFixtures.document([hairpin, bar])).hitTest(at: point)
            == .spanner(anchor: ElementHitFixtures.anchor, kind: .hairpin))
    }

    @Test("An earlier measure's arc cannot steal a later note or rest", arguments: [false, true])
    func arcAfterNoteAndRest(isRest: Bool) {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let rest = RestID(staff: ElementHitFixtures.anchor.staff, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
        let element = isRest ? LayoutElement.rest(
            duration: .quarter, origin: ElementHitFixtures.origin, voiceIndex: 0, restID: rest, hasLegerLine: false,
        ) : ElementHitFixtures.chord()
        let id = SlurID.chord(anchor: ElementHitFixtures.anchor, ordinal: 0)
        // A 100-point arc has a 15-point apex lift. Baseline y=95 puts its apex at (180,80).
        let arc = LayoutElement.tieArc(
            fromOrigin: CGPoint(x: 130, y: 95), toOrigin: CGPoint(x: 230, y: 95),
            above: true, identity: .slur(id),
        )
        let system = LayoutSystem(
            origin: .zero, size: .init(width: 400, height: 200),
            measures: [
                LayoutMeasure(measureIndex: 0, origin: .zero, width: 170, elements: [arc]),
                LayoutMeasure(measureIndex: 1, origin: CGPoint(x: 100, y: 0), width: 200, elements: [element]),
            ], staffOrigins: [], partLabels: [], spanners: [], sp: 10,
        )
        let tester = ScoreHitTester(document: LayoutDocument(
            size: system.size, systems: [system], metrics: ElementHitFixtures.metrics,
        ))
        let point = CGPoint(x: 180, y: 80)
        #expect(tester.hitElement(at: point) == .slur(id))
        #expect(tester.hitTest(at: point) == (isRest ? .rest(rest) : .note(ElementHitFixtures.noteID)))
    }
}
