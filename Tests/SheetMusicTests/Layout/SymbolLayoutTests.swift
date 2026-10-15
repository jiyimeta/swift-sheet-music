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

/// `<Symbol>` annotations: a glyph by SMuFL name, at the segment (or the note), sized and turned only when it names
/// its own font.
@Suite("Symbol layout")
struct SymbolLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures
    private static let headHalfWidth = 1.18 * F.sp / 2

    private static func f5(_ duration: NoteDuration = .half) -> VoiceElement {
        .chord(Chord(duration: duration, notes: ChordNotes([Note(pitch: 77, tpc: 13)])))
    }

    private struct Drawn {
        let codepoint: UInt32
        let size: CGFloat
        let baseline: CGPoint
        let rotation: CGFloat
        let kind: LayoutFigure.Kind
    }

    private static func symbols(_ document: LayoutDocument) -> [Drawn] {
        F.elements(document).compactMap { element -> Drawn? in
            guard case let .figure(kind, figure, _, _) = element, kind == .symbol,
                  case let .run(run, rotation, _)? = figure.primitives.first,
                  case let .symbol(codepoint) = run.content else { return nil }
            return Drawn(
                codepoint: codepoint, size: run.font.pointSize, baseline: run.baseline, rotation: rotation, kind: kind,
            )
        }
    }

    @Test("a symbol with its own font: 4 sp × symbolsSize, turned by symbolAngle, baseline on the staff's top line")
    func ownFontSymbol() throws {
        let trill = EngravingSymbol(name: "ornamentTrill", scoreFont: "Bravura", size: 1.5, angle: -12.25)
        let document = F.layout(F.score([Self.f5(), .symbol(trill), Self.f5()]))
        let drawn = try #require(Self.symbols(document).first)
        #expect(drawn.codepoint == 0xE566)
        #expect(abs(drawn.size - 4 * F.sp * 1.5) < 0.001)
        #expect(abs(drawn.rotation - (-12.25 * .pi / 180)) < 1e-6)
        // F5 sits on the top staff line: the symbol's baseline is that line.
        let noteY = try #require(F.chordNoteY(document, nth: 0))
        #expect(abs(drawn.baseline.y - noteY) < 0.01)
        // Left edge at the segment: the second chord's notehead left edge.
        let noteX = try #require(F.chordNoteX(document, nth: 1))
        #expect(abs(drawn.baseline.x - (noteX - Self.headHalfWidth)) < 0.01)
    }

    @Test("without a font of its own, size and angle are ignored")
    func plainSymbol() throws {
        let plain = EngravingSymbol(name: "ornamentTrill", size: 2, angle: 30)
        let drawn = try #require(Self.symbols(F.layout(F.score([Self.f5(), .symbol(plain)]))).first)
        #expect(abs(drawn.size - 4 * F.sp) < 0.001)
        #expect(drawn.rotation == 0)
    }

    @Test("offset moves it, an unknown name draws nothing, hidden is a ghost, and it is not in the skyline")
    func offsetUnknownHidden() throws {
        var moved = EngravingSymbol(name: "ornamentTurn")
        moved.elementProperties.offset = ScoreOffset(x: 1, y: -2)
        var base = EngravingSymbol(name: "ornamentTurn")
        let a = try #require(Self.symbols(F.layout(F.score([Self.f5(), .symbol(moved)]))).first)
        let b = try #require(Self.symbols(F.layout(F.score([Self.f5(), .symbol(base)]))).first)
        #expect(abs((a.baseline.x - b.baseline.x) - F.sp) < 0.001)
        #expect(abs((a.baseline.y - b.baseline.y) + 2 * F.sp) < 0.001)
        #expect(Self.symbols(F.layout(F.score([Self.f5(), .symbol(EngravingSymbol(name: "futureGlyph"))]))).isEmpty)
        base.visible = false
        let score = F.score([Self.f5(), .symbol(base)])
        #expect(Self.symbols(F.layout(score)).isEmpty)
        let ghosts = F.layout(score, showsInvisible: true).systems.flatMap(\.measures).flatMap(\.invisibleElements)
        #expect(ghosts.count { if case .figure = $0 { true } else { false } } == 1)
        let element = LayoutElement.figure(kind: .symbol, figure: LayoutFigure(primitives: []))
        #expect(LayoutElementShape.kind(of: element) == nil)
    }

    @Test("a note's symbol starts at the note's left edge on the note's line; a notehead parenthesis is not one")
    func noteSymbols() throws {
        var note = Note(pitch: 77, tpc: 13)
        note.symbols = [EngravingSymbol(name: "ornamentTurn")]
        let chord = VoiceElement.chord(Chord(duration: .whole, notes: ChordNotes([note])))
        let document = F.layout(F.score([chord]))
        let drawn = try #require(Self.symbols(document).first)
        let noteY = try #require(F.chordNoteY(document, nth: 0))
        let noteX = try #require(F.chordNoteX(document, nth: 0))
        #expect(abs(drawn.baseline.y - noteY) < 0.01)
        #expect(abs(drawn.baseline.x - (noteX - Self.headHalfWidth)) < 0.01)
        // The decoder keeps notehead parentheses in `Note.parentheses`, never in `symbols`.
        let guitar = try F.load("guitarbend_prebend")
        let drawnGuitar = Self.symbols(F.layout(guitar))
        #expect(drawnGuitar.isEmpty)
    }

    @Test("MuseScore's own bars: the trill with its angle, the future glyphs dropped")
    func fixtureBars() throws {
        let drawn = try Self.symbols(F.layout(F.load("annotation-symbol")))
        #expect(drawn.map(\.codepoint) == [0xE566])
        #expect(drawn.map(\.kind) == [.symbol])
    }
}
