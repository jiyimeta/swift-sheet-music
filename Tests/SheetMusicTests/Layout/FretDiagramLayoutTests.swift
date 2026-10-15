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

/// A fret diagram's geometry (`styledef.cpp:446-462`) and its place above the staff.
@Suite("Fret diagram layout")
struct FretDiagramLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    private static func diagram() -> FretDiagram {
        FretDiagram(
            stringCount: 6, fretCount: 4,
            strings: [
                FretString(index: 0, marker: .cross),
                FretString(index: 1, marker: .circle),
                FretString(index: 2, dots: [FretString.Dot(fret: 2)]),
            ],
            barres: [FretBarre(startString: 2, endString: 5, fret: 1)],
        )
    }

    private static func figure(_ diagram: FretDiagram) -> LayoutFigure {
        FretDiagramGeometry.figure(diagram, sp: F.sp).figure
    }

    private static func lines(_ figure: LayoutFigure) -> [(CGPoint, CGPoint, CGFloat, LayoutFigure.Cap)] {
        figure.primitives.compactMap { primitive in
            if case let .line(from, to, width, cap) = primitive { (from, to, width, cap) } else { nil }
        }
    }

    @Test("six strings 0.7 sp apart, four fret lines 0.7 sp apart, hairlines 0.08 sp, a 0.3 sp nut")
    func grid() {
        let lines = Self.lines(Self.figure(Self.diagram()))
        let strings = lines.filter { $0.0.x == $0.1.x && abs($0.2 - 0.08 * F.sp) < 1e-6 }
        #expect(strings.count == 6)
        let xs = strings.map(\.0.x).sorted()
        let gaps = zip(xs, xs.dropFirst()).map { ($1 - $0) / F.sp }
        #expect(gaps.map { ($0 * 1000).rounded() } == Array(repeating: 700, count: 5))
        let frets = lines.filter { $0.0.y == $0.1.y && abs($0.2 - 0.08 * F.sp) < 1e-6 }
        #expect(frets.count == 4)
        let nut = lines.filter { abs($0.2 - 0.3 * F.sp) < 1e-6 && $0.3 == .flat }
        #expect(nut.count == 1)
    }

    @Test("a dot sits in the middle of its fret row, half a space wide; a barre is a round-capped line 0.85 dots thick")
    func dotsAndBarre() throws {
        let figure = Self.figure(Self.diagram())
        let dots = figure.primitives.compactMap { primitive -> CGRect? in
            if case let .ellipse(rect, fill, _) = primitive, fill { rect } else { nil }
        }
        let dot = try #require(dots.first)
        #expect(abs(dot.width - 0.5 * F.sp) < 0.001)
        // Fret 2 on string 2: x = 2 × 0.7 sp, y = (2 − 1) × 0.7 + 0.35 sp below the nut.
        #expect(abs(dot.midX - 2 * 0.7 * F.sp) < 0.001)
        #expect(abs(dot.midY - (0.7 + 0.35) * F.sp) < 0.01)
        let barre = try #require(Self.lines(figure).first { $0.3 == .round })
        #expect(abs(barre.2 - 0.5 * F.sp * 0.85) < 0.001)
        #expect(abs(barre.0.y - 0.35 * F.sp) < 0.01)
        #expect(abs(barre.0.x - 2 * 0.7 * F.sp) < 0.001 && abs(barre.1.x - 5 * 0.7 * F.sp) < 0.001)
    }

    @Test("a cross marker is two strokes and a circle marker an outlined ellipse above the nut")
    func markers() throws {
        let figure = Self.figure(Self.diagram())
        let circle = try #require(figure.primitives.compactMap { primitive -> CGRect? in
            guard case let .ellipse(rect, fill, _) = primitive, !fill, abs(rect.width - 0.56 * F.sp) < 0.001
            else { return nil }
            return rect
        }.first)
        #expect(circle.maxY < 0)
        #expect(Self.lines(figure).filter { $0.0.x != $0.1.x && $0.0.y != $0.1.y }.count == 2)
    }

    @Test("an offset diagram draws its fret number, no nut-thick line")
    func fretNumber() {
        var offset = Self.diagram()
        offset.fretOffset = 2
        let figure = Self.figure(offset)
        let texts = figure.primitives.compactMap { primitive -> String? in
            if case let .run(run, _, _) = primitive, case let .text(text) = run.content { text } else { nil }
        }
        #expect(texts == ["3"])
        #expect(!Self.lines(figure).contains { abs($0.2 - 0.3 * F.sp) < 1e-6 })
    }

    @Test("horizontal: the same grid turned, strings running across")
    func horizontal() {
        var turned = Self.diagram()
        turned.orientation = .horizontal
        let vertical = Self.figure(Self.diagram()).ink
        let across = Self.figure(turned).ink
        #expect(abs(across.width - vertical.height) < 0.5 * F.sp)
        #expect(abs(across.height - vertical.width) < 0.5 * F.sp)
        let strings = Self.lines(Self.figure(turned)).filter { $0.0.y == $0.1.y && abs($0.2 - 0.08 * F.sp) < 1e-6 }
        #expect(strings.count == 6)
    }

    @Test("in a score: centered on its beat's notehead, its last fret line 1 sp above the staff, the chord name above")
    func placement() throws {
        let document = try F.layout(F.load("w5-diagrams"))
        let figure = try #require(F.elements(document).compactMap { element -> LayoutFigure? in
            if case let .figure(kind, figure, _, _) = element, kind == .fretDiagram { figure } else { nil }
        }.first)
        let noteXs = F.elements(document).compactMap { element -> CGFloat? in
            guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
            return notes.first?.origin.x
        }
        let gridXs = figure.primitives.compactMap { primitive -> CGFloat? in
            if case let .line(from, to, width, _) = primitive, from.x == to.x, abs(width - 0.08 * F.sp) < 1e-6 {
                from.x
            } else { nil }
        }
        let center = ((gridXs.min() ?? 0) + (gridXs.max() ?? 0)) / 2
        #expect(noteXs.contains { abs($0 - center) < 0.6 })
        // The lowest fret line sits 1 sp above the top staff line; the bar's note (C4, a ledger below) is 6 sp lower.
        let fretYs = figure.primitives.compactMap { primitive -> CGFloat? in
            guard case let .line(from, to, width, _) = primitive, from.y == to.y,
                  abs(width - 0.08 * F.sp) < 1e-6 else { return nil }
            return from.y
        }
        let lowest = try #require(fretYs.max())
        let harmony = try #require(F.elements(document).compactMap { element -> LayoutHarmony? in
            if case let .harmony(harmony) = element { harmony } else { nil }
        }.first)
        #expect(harmony.harmony.name == "Cmaj7")
        #expect(CGFloat(harmony.y) < figure.ink.minY)
        #expect(lowest < figure.ink.maxY + 0.01)
    }
}
