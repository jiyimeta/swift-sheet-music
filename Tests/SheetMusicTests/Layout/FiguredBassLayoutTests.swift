#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Figured bass: the glyph string of an item, items stacked below the staff, the digit centered under the note, the
/// continuation line.
@Suite("Figured bass layout")
struct FiguredBassLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures
    private typealias G = FiguredBassGeometry

    private func name(_ n: String) -> UInt32 {
        SMuFLCodepoint.byName(n) ?? 0
    }

    private static func figures(_ document: LayoutDocument) -> [(LayoutFigure, TextPlacementMetadata?)] {
        F.elements(document).compactMap { element -> (LayoutFigure, TextPlacementMetadata?)? in
            guard case let .figure(kind, figure, _, placement) = element, kind == .figuredBass else { return nil }
            return (figure, placement)
        }
    }

    @Test("an item spells parenthesis, prefix, digit, suffix, parenthesis — and a slashed six is the raised glyph")
    func glyphStrings() {
        #expect(G.glyphs(for: FiguredBassItem(digit: 6)) == [name("figbass6")])
        #expect(G.glyphs(for: FiguredBassItem(prefix: .flat, digit: 4, suffix: .sharp))
            == [name("figbassFlat"), name("figbass4"), name("figbassSharp")])
        #expect(G.glyphs(for: FiguredBassItem(digit: 6, suffix: .slash)) == [name("figbass6Raised")])
        #expect(G.glyphs(for: FiguredBassItem(digit: 3, suffix: .backslash))
            == [name("figbass3"), name("figbassCombiningLowering")])
        #expect(G.glyphs(for: FiguredBassItem(digit: 4, suffix: .cross)) == [name("figbass4"), name("figbassPlus")])
        #expect(G.glyphs(for: FiguredBassItem(digit: 12)) == [name("figbass1"), name("figbass2")])
        #expect(G.glyphs(for: FiguredBassItem(prefix: .natural)) == [name("figbassNatural")])
        #expect(G.glyphs(for: FiguredBassItem(digit: 7, bracket0: .roundOpen, bracket3: .roundClosed))
            == [name("figbassParensLeft"), name("figbass7"), name("figbassParensRight")])
        // A parenthesis between digit and suffix stops the combination.
        #expect(G.glyphs(for: FiguredBassItem(digit: 6, suffix: .slash, bracket2: .roundOpen))
            == [name("figbass6"), name("figbassParensLeft"), name("figbassCombiningRaising")])
    }

    @Test("a sixth sits under the staff, its digit centered under the note")
    func simpleFigure() throws {
        let document = try F.layout(F.load("figured-bass"))
        let first = try #require(Self.figures(document).first?.0)
        let digit = try #require(first.primitives.compactMap { primitive -> LayoutRichTextPositionedRun? in
            if case let .run(run, _, _) = primitive { run } else { nil }
        }.first)
        #expect(digit.font.pointSize > 0)
        // 6 sp below the top line: well under the bar's own note.
        let noteY = try #require(F.chordNoteY(document, nth: 0))
        #expect(first.ink.minY > noteY)
        let noteX = try #require(F.chordNoteX(document, nth: 0))
        #expect(abs(first.ink.midX - noteX) < 0.6 * F.sp)
    }

    @Test("two items stack a line pitch apart; the continuation line is 3/32 sp thick with round caps")
    func stackAndLine() throws {
        let figured = FiguredBass(items: [
            FiguredBassItem(digit: 4, continuationLine: .simple), FiguredBassItem(digit: 3),
        ], ticks: Fraction(numerator: 1, denominator: 1))
        let figure = G.figure(figured, columnX: 100, topY: 8 * F.sp, lineEndX: 100 + 10 * F.sp, sp: F.sp)
        let baselines = figure.primitives.compactMap { primitive -> CGFloat? in
            guard case let .run(run, _, _) = primitive else { return nil }
            return run.baseline.y
        }
        // 4 (first item) and 3 (second): glyphs of one item share a baseline, the next is a line pitch lower.
        #expect(Set(baselines.map { ($0 * 100).rounded() }).count == 2)
        #expect(abs((baselines.max() ?? 0) - (baselines.min() ?? 0) - G.linePitchSp * F.sp) < 0.01)
        let lines = figure.primitives.compactMap { primitive -> (CGPoint, CGPoint, CGFloat, LayoutFigure.Cap)? in
            guard case let .line(from, to, width, cap) = primitive else { return nil }
            return (from, to, width, cap)
        }
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(abs(line.2 - 3.0 / 32.0 * F.sp) < 0.001)
        #expect(line.3 == .round)
        #expect(abs(line.1.x - (100 + 10 * F.sp)) < 0.001)
    }

    /// Measured off MuseScore 4.7's engraving of this fixture at 600 dpi (41.25 px a space): bar 2's "4" has its top
    /// 6.35 sp and its baseline 7.49 sp under the top line, and the "3" under it its baseline at 9.14 sp.
    @Test("the figures sit where MuseScore engraves them: baselines 7.49 and 9.14 sp under the top line")
    func calibratedAgainstMuseScore() throws {
        let document = try F.layout(F.load("figured-bass"))
        let second = try #require(Self.figures(document).dropFirst().first?.0)
        // Bar 2's E4 is on the bottom line: the top line is 4 sp above it.
        let topLine = try #require(F.chordNoteY(document, nth: 1)) - 4 * F.sp
        let baselines = Set(second.primitives.compactMap { primitive -> CGFloat? in
            if case let .run(run, _, _) = primitive { (run.baseline.y - topLine) / F.sp } else { nil }
        }).sorted()
        try #require(baselines.count == 2)
        #expect(abs(baselines[0] - 7.49) < 0.05)
        #expect(abs(baselines[1] - 9.14) < 0.05)
    }

    /// MuseScore lays every figure out at its fixed offset below and lets autoplace carry one placed above over the
    /// staff (`Autoplace::autoplaceSegmentElement`) — the fixture's third bar, whose sharp MuseScore 4.7 draws with its
    /// bottom about a space above the top line.
    @Test("a figure placed above sits over the staff, its bottom about a space above the top line")
    func placedAbove() throws {
        let document = try F.layout(F.load("figured-bass"))
        let figures = Self.figures(document)
        try #require(figures.count == 3)
        let above = figures[2]
        #expect(above.1?.side == .above)
        // The bar's G4 is on the second line: the top line is 3 sp above it.
        let topLine = try #require(F.chordNoteY(document, nth: 2)) - 3 * F.sp
        #expect(abs(above.0.ink.maxY - (topLine - F.sp)) < 0.25 * F.sp)
    }

    @Test("text that did not parse draws as its lines; a hidden figure is a ghost; autoplace is off below")
    func textOnlyAndHidden() throws {
        let document = try F.layout(F.load("figured-bass"))
        let figures = Self.figures(document)
        #expect(figures.count == 3)
        #expect(figures.map { $0.1?.autoplace } == [false, false, true])
        let textRuns = figures.last?.0.primitives.compactMap { primitive -> String? in
            if case let .run(run, _, _) = primitive, case let .text(text) = run.content { text } else { nil }
        }
        #expect(textRuns == ["7", "#"])
        var hidden = FiguredBass(items: [FiguredBassItem(digit: 6)])
        hidden.visible = false
        let score = F.score([.figuredBass(hidden), F.whole()])
        #expect(F.elements(F.layout(score)).contains { if case .figure = $0 { true } else { false } } == false)
        let ghosts = F.layout(score, showsInvisible: true).systems.flatMap(\.measures).flatMap(\.invisibleElements)
        #expect(ghosts.count { if case .figure = $0 { true } else { false } } == 1)
    }
}
