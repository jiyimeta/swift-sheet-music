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

/// The carrier itself: its ink is the union of what it draws, translating moves everything, a rotated glyph's ink
/// follows the rotation.
@Suite("Layout figure")
struct LayoutFigureTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func head(at baseline: CGPoint) -> LayoutRichTextPositionedRun {
        LayoutRichTextPositionedRun(
            content: .symbol(codepoint: SMuFLCodepoint.noteheadBlack),
            font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 28), baseline: baseline,
        )
    }

    @Test("the ink is the union of strokes (with their width), ellipses and runs")
    func inkIsTheUnion() {
        let figure = LayoutFigure(primitives: [
            .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), width: 2, cap: .flat),
            .ellipse(rect: CGRect(x: 20, y: -5, width: 4, height: 4), fill: true, width: 0),
            .run(Self.head(at: CGPoint(x: 10, y: 20)), rotation: 0, pivot: CGPoint(x: 10, y: 20)),
        ])
        #expect(figure.ink.minX <= 0)
        #expect(figure.ink.minY <= -5)
        #expect(figure.ink.maxX >= 24)
        #expect(figure.ink.contains(CGPoint(x: 12, y: 20)))
        // The line's half width reaches past its centerline.
        let lineOnly = LayoutFigure(primitives: [.line(from: .zero, to: CGPoint(x: 10, y: 0), width: 2, cap: .flat)])
        #expect(lineOnly.ink.minY <= -1 && lineOnly.ink.maxY >= 1)
        #expect(LayoutFigure(primitives: []).ink == .zero)
    }

    @Test("translating moves the ink, the runs and the strokes together")
    func translated() {
        let figure = LayoutFigure(primitives: [
            .line(from: .zero, to: CGPoint(x: 10, y: 0), width: 2, cap: .round),
            .run(Self.head(at: CGPoint(x: 10, y: 20)), rotation: 0.5, pivot: CGPoint(x: 14, y: 18)),
        ])
        let moved = figure.translated(dx: 100, dy: -30)
        #expect(moved.ink == figure.ink.offsetBy(dx: 100, dy: -30))
        guard case let .line(from, to, _, cap) = moved.primitives[0],
              case let .run(run, rotation, pivot) = moved.primitives[1]
        else {
            Issue.record("primitive kinds changed")
            return
        }
        #expect(from == CGPoint(x: 100, y: -30) && to == CGPoint(x: 110, y: -30) && cap == .round)
        #expect(run.baseline == CGPoint(x: 110, y: -10))
        #expect(rotation == 0.5)
        #expect(pivot == CGPoint(x: 114, y: -12))
    }

    @Test("a glyph rotated a quarter turn about its center has the unrotated ink's size, turned")
    func rotatedInk() {
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 28)
        let run = LayoutRichTextPositionedRun(
            content: .symbol(codepoint: SMuFLCodepoint.byName("ornamentTrill") ?? 0xE566), font: font,
            baseline: CGPoint(x: 50, y: 50),
        )
        let plain = LayoutFigure(primitives: [.run(run, rotation: 0, pivot: .zero)]).ink
        let center = CGPoint(x: plain.midX, y: plain.midY)
        let turned = LayoutFigure(primitives: [.run(run, rotation: .pi / 2, pivot: center)]).ink
        #expect(plain.width > 0 && plain.height > 0)
        #expect(abs(turned.width - plain.height) < 0.01)
        #expect(abs(turned.height - plain.width) < 0.01)
        #expect(abs(turned.midX - center.x) < 0.01 && abs(turned.midY - center.y) < 0.01)
    }

    /// The sign every renderer must agree on: a positive angle turns clockwise on screen (Qt's `rotate`, which
    /// `symbolAngle` feeds), so in this y-down space a glyph to the right of its pivot swings down.
    @Test("a positive rotation turns clockwise on screen: right of the pivot moves down")
    func rotationDirection() {
        let run = LayoutRichTextPositionedRun(
            content: .symbol(codepoint: SMuFLCodepoint.byName("ornamentTrill") ?? 0xE566),
            font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 28), baseline: CGPoint(x: 100, y: 50),
        )
        let pivot = CGPoint(x: 0, y: 50)
        let plain = LayoutFigure(primitives: [.run(run, rotation: 0, pivot: pivot)]).ink
        let clockwise = LayoutFigure(primitives: [.run(run, rotation: 0.3, pivot: pivot)]).ink
        let counter = LayoutFigure(primitives: [.run(run, rotation: -0.3, pivot: pivot)]).ink
        #expect(clockwise.midY > plain.midY + 20)
        #expect(counter.midY < plain.midY - 20)
    }
}
