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

/// An ambitus: noteheads on their staff rows, a line between, ledger lines, and a header column of its own.
@Suite("Ambitus layout")
struct AmbitusLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    private static let ambitus = Ambitus(topPitch: 77, topTpc: 13, bottomPitch: 60, bottomTpc: 14)

    private static func figure(_ document: LayoutDocument) -> LayoutFigure? {
        F.elements(document).compactMap { element -> LayoutFigure? in
            if case let .figure(kind, figure, _, _) = element, kind == .ambitus { figure } else { nil }
        }.first
    }

    private static func timeSignatureX(_ document: LayoutDocument) -> CGFloat? {
        F.elements(document).compactMap { element -> CGFloat? in
            if case let .timeSignature(_, _, _, origin, _) = element { origin.x } else { nil }
        }.first
    }

    private static func heads(_ figure: LayoutFigure) -> [LayoutRichTextPositionedRun] {
        figure.primitives.compactMap { primitive -> LayoutRichTextPositionedRun? in
            guard case let .run(run, _, _) = primitive, case let .symbol(codepoint) = run.content,
                  codepoint == SMuFLCodepoint.noteheadBlack
            else { return nil }
            return run
        }
    }

    @Test("F5 and middle C on a treble clef: the top head on the top line, the bottom on its first ledger line")
    func noteheadRows() throws {
        let score = F.score([
            .clef(Clef(concertClefType: "G")), .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .ambitus(Self.ambitus), F.whole(),
        ])
        let document = F.layout(score)
        let figure = try #require(Self.figure(document))
        let heads = Self.heads(figure)
        try #require(heads.count == 2)
        let top = heads[0].baseline.y
        let bottom = heads[1].baseline.y
        // F5 is the top line; C4 is one ledger line below the bottom line: 10 steps, 5 sp.
        #expect(abs((bottom - top) - 5 * F.sp) < 0.01)
        // The bar's C5 sits three steps below the top line.
        let c5 = try #require(F.chordNoteY(document))
        #expect(abs(top - (c5 - 1.5 * F.sp)) < 0.01)
        let ledgers = figure.primitives.compactMap { primitive -> (CGPoint, CGPoint, CGFloat)? in
            guard case let .line(from, to, width, _) = primitive, from.y == to.y else { return nil }
            return (from, to, width)
        }
        #expect(ledgers.count == 1)
        #expect(ledgers.allSatisfy { abs($0.0.y - bottom) < 0.01 && abs($0.2 - 0.16 * F.sp) < 0.001 })
        #expect(heads[0].baseline.x == heads[1].baseline.x)
    }

    @Test("the connecting line stops 0.8 sp short of each head center, 0.12 sp wide; hasLine off removes it")
    func connectingLine() throws {
        let figure = try #require(Self.figure(F.layout(F.score([.ambitus(Self.ambitus), F.whole()]))))
        let vertical = figure.primitives.compactMap { primitive -> (CGPoint, CGPoint, CGFloat)? in
            if case let .line(from, to, width, _) = primitive, from.x == to.x { (from, to, width) } else { nil }
        }
        let line = try #require(vertical.first)
        let heads = Self.heads(figure).map(\.baseline.y)
        try #require(heads.count == 2)
        #expect(abs(line.0.y - (heads[0] + 0.8 * F.sp)) < 0.01)
        #expect(abs(line.1.y - (heads[1] - 0.8 * F.sp)) < 0.01)
        #expect(abs(line.2 - 0.12 * F.sp) < 0.001)
        var bare = Self.ambitus
        bare.hasLine = false
        let none = try #require(Self.figure(F.layout(F.score([.ambitus(bare), F.whole()]))))
        #expect(!none.primitives.contains { if case let .line(from, to, _, _) = $0 { from.x == to.x } else { false } })
    }

    @Test("a sharp F hangs an accidental to the left of its head")
    func accidentals() throws {
        let sharp = Ambitus(topPitch: 78, topTpc: 20, bottomPitch: 60, bottomTpc: 14)
        let figure = try #require(Self.figure(F.layout(F.score([.ambitus(sharp), F.whole()]))))
        let runs = figure.primitives.compactMap { primitive -> LayoutRichTextPositionedRun? in
            if case let .run(run, _, _) = primitive { run } else { nil }
        }
        #expect(runs.count == 3)
        func run(drawing codepoint: UInt32) -> LayoutRichTextPositionedRun? {
            runs.first { if case let .symbol(code) = $0.content { code == codepoint } else { false } }
        }
        let head = try #require(run(drawing: SMuFLCodepoint.noteheadBlack))
        let accidental = try #require(run(drawing: SMuFLCodepoint.accidentalSharp))
        #expect(accidental.baseline.x < head.baseline.x)
    }

    @Test("it takes a column between the key signature and the time signature, and only where it stands")
    func headerColumn() throws {
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")), .keySignature(KeySignature(concertKey: 2)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ]
        let without = F.layout(F.score(elements + [F.whole()]))
        let with = F.layout(F.score(elements + [.ambitus(Self.ambitus), F.whole()]))
        let figure = try #require(Self.figure(with))
        let withX = try #require(Self.timeSignatureX(with))
        let withoutX = try #require(Self.timeSignatureX(without))
        // The column holds the heads and accidentals plus MuseScore's 0.5 sp `ambitusMargin`; the ledger lines'
        // overhang is not in MuseScore's bbox either, but still clears the time signature's anchor.
        #expect(withX - withoutX > 1.18 * F.sp)
        #expect(figure.ink.maxX < withX)
        let keyX = F.elements(with).compactMap { element -> CGFloat? in
            if case let .keySignature(_, _, _, _, origin, _) = element { origin.x } else { nil }
        }.first ?? 0
        #expect(figure.ink.minX > keyX)
        // A score with no ambitus lays out exactly as before.
        #expect(Self.timeSignatureX(without) == Self.timeSignatureX(F.layout(F.score(elements + [F.whole()]))))
    }

    @Test("MuseScore's own bars lay out; a hidden ambitus is a ghost")
    func fixtureAndHidden() throws {
        let document = try F.layout(F.load("ambitus"))
        let figures = F.elements(document).filter { if case .figure = $0 { true } else { false } }
        #expect(figures.count == 3)
        var hidden = Self.ambitus
        hidden.visible = false
        let score = F.score([.ambitus(hidden), F.whole()])
        #expect(Self.figure(F.layout(score)) == nil)
        let ghosts = F.layout(score, showsInvisible: true).systems.flatMap(\.measures).flatMap(\.invisibleElements)
        #expect(ghosts.count { if case .figure = $0 { true } else { false } } == 1)
    }
}
