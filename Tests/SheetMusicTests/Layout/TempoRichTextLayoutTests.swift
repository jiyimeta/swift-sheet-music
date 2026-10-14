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

/// A tempo marking is typeset from runs: the derived "♩ = N" with its metronome glyph a Bravura symbol run at the tempo
/// style's symbol size, an authored text with its words and formatting, a MuseScore 2/3 `ScoreText` character as the
/// glyph it stands for — and layout's ink and skyline read those same runs.
@Suite("Tempo text in layout")
struct TempoRichTextLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private static let metrics = StaffMetrics(staffSize: 20)
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private struct Found {
        let element: LayoutElement
        let origin: CGPoint
        let rich: LayoutRichText?
    }

    private static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
    }

    private static func score(_ tempo: Tempo) -> Score {
        var score = EditingFixtures.fourQuarterRests()
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(tempo), originalStaff: staff),
        ])]
        return score
    }

    private static func tempos(_ document: LayoutDocument) -> [Found] {
        document.systems.flatMap(\.measures).flatMap(\.elements).compactMap { element in
            guard case let .textMark(.tempo, _, origin, rich) = element else { return nil }
            return Found(element: element, origin: origin, rich: rich)
        }
    }

    private static func contents(_ rich: LayoutRichText?) -> [LayoutRichTextRun.Content] {
        rich?.lines.flatMap(\.runs).map(\.content) ?? []
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6
            && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    @Test("a derived marking is the metronome glyph and the number")
    func derivedMarkingCarriesRuns() throws {
        let tempo = try #require(Self.tempos(Self.layout(Self.score(Tempo(beatsPerSecond: 2)))).first)
        #expect(Self.contents(tempo.rich) == [.symbol(codepoint: 0xECA5), .text(" = 120")])
    }

    @Test("an authored marking draws its words, bold as the tempo style is")
    func authoredWordsAreTheRuns() throws {
        let document = Self.layout(Self.score(Tempo(beatsPerSecond: 2.4, text: "Allegro")))
        let tempo = try #require(Self.tempos(document).first)
        #expect(Self.contents(tempo.rich) == [.text("Allegro")])
        #expect(tempo.rich?.lines.first?.runs.first?.font.weight == .bold)
    }

    @Test("the metronome glyph is set in Bravura at the tempo symbol size, larger than the text")
    func metronomeGlyphUsesTempoSymbolSize() throws {
        let tempo = try #require(Self.tempos(Self.layout(Self.score(Tempo(beatsPerSecond: 2)))).first)
        let runs = try #require(tempo.rich?.lines.first?.runs)
        let glyph = try #require(runs.first)
        let number = try #require(runs.last)
        #expect(glyph.font.face == SMuFLFamily.bravura)
        #expect(glyph.font.pointSize > number.font.pointSize)
    }

    @Test("a ScoreText character is the glyph it stands for; its neighbors stay text")
    func scoreTextFaceIsAGlyph() throws {
        let legacy = RichText(lines: [[
            .text("\u{ECA5}", RichTextFormat(face: "ScoreText")),
            .text(" = 60", RichTextFormat(bold: true, face: "FreeSerif")),
        ]])
        #expect(Self.contents(LayoutRichText(legacy, style: .tempo, metrics: Self.metrics))
            == [.symbol(codepoint: 0xECA5), .text(" = 60")])
        let mixed = LayoutRichText(
            RichText(lines: [[.text("a\u{ECA5}b", RichTextFormat(face: "ScoreText"))]]),
            style: .tempo, metrics: Self.metrics,
        )
        #expect(Self.contents(mixed) == [.text("a"), .symbol(codepoint: 0xECA5), .text("b")])
        #expect(mixed.lines.first?.runs.first?.font.face != "ScoreText")
        let fixture = try MSCXParser.parse(MSCXFixtureLoader.mscxData("testVoltaTemp"))
        let drawn = try #require(Self.tempos(Self.layout(fixture)).first)
        #expect(Self.contents(drawn.rich).first == .symbol(codepoint: 0xECA5))
    }

    @Test("ink and skyline are the runs' — the same LayoutRichText the renderers draw")
    func inkAndSkylineComeFromRuns() throws {
        let document = Self.layout(Self.score(Tempo(beatsPerSecond: 2, text: "Allegro")))
        let tempo = try #require(Self.tempos(document).first)
        let rich = try #require(tempo.rich)
        let ink = try #require(TextInkGeometry.rects(for: tempo.element, metrics: document.metrics)?.first)
        let expected = try #require(rich.inkRect(at: tempo.origin, anchor: LayoutRichText.anchor(for: .tempo)))
        #expect(Self.close(ink, expected))
        let shape = try #require(LayoutElementShape.shape(
            for: tempo.element, id: 0, xOffset: 0, metrics: document.metrics,
        ))
        let box = try #require(shape.bbox)
        #expect(Self.close(box, LayoutElementShape.textRect(rich: rich, origin: tempo.origin, kind: .tempo)))
    }

    @Test("a tempo element built without runs is typeset from its plain text the same way")
    func plainTempoElementIsTypesetLikeTheMarking() throws {
        let origin = CGPoint(x: 30, y: 0)
        let element = LayoutElement.textMark(kind: .tempo(anchor: nil), text: "\u{E1D5} = 120", origin: origin)
        let rich = LayoutRichText.tempoText("\u{E1D5} = 120", metrics: Self.metrics)
        #expect(Self.contents(rich) == [.symbol(codepoint: 0xE1D5), .text(" = 120")])
        let ink = try #require(TextInkGeometry.rects(for: element, metrics: Self.metrics)?.first)
        let expected = try #require(rich.inkRect(at: origin, anchor: LayoutRichText.anchor(for: .tempo)))
        #expect(Self.close(ink, expected))
    }
}
