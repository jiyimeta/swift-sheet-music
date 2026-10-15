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
#endif

/// Every line kind's label is typeset as runs (symbols included), on every system the line reaches, and the end label
/// travels beside it.
@Suite("Line label runs in layout")
struct LineLabelRunsLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private struct Seg {
        let kind: LayoutElement.SpannerKind
        let continuesLeft: Bool
        let rich: LayoutRichText?
        let detail: LayoutLineDetail?
    }

    private static func segments(_ document: LayoutDocument) -> [Seg] {
        document.systems.flatMap(\.spanners).compactMap { element in
            guard case let .spannerSegment(kind, _, _, left, _, _, _, rich, detail) = element else { return nil }
            return Seg(kind: kind, continuesLeft: left, rich: rich, detail: detail)
        }
    }

    private static func contents(_ rich: LayoutRichText?) -> [LayoutRichTextRun.Content] {
        rich?.lines.flatMap(\.runs).map(\.content) ?? []
    }

    private static func layout(_ name: String, width: CGFloat = 1400) throws -> [Seg] {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
        return segments(LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: width))
    }

    @Test("a bare pedal's label is the Ped glyph; its continuation on a later system is Ped in parentheses")
    func pedalLabels() throws {
        let pedals = try Self.layout("pedal-lines", width: 260).filter { $0.kind == .pedal }
        let first = try #require(pedals.first { !$0.continuesLeft })
        #expect(Self.contents(first.rich) == [.symbol(codepoint: 0xE650)])
        if let continued = pedals.first(where: { $0.continuesLeft }) {
            #expect(Self.contents(continued.rich) == [
                .symbol(codepoint: 0xE676), .symbol(codepoint: 0xE650), .symbol(codepoint: 0xE677),
            ])
        }
    }

    @Test("the asterisk pedal carries the rosette as its end label and no begin hook text")
    func asteriskEnd() throws {
        let pedals = try Self.layout("pedal-lines").filter { $0.kind == .pedal }
        let asterisk = try #require(pedals.first { $0.detail?.lineVisible == false })
        #expect(Self.contents(asterisk.detail?.endRichText) == [.symbol(codepoint: 0xE655)])
        #expect(asterisk.detail?.endHook == .rosette)
    }

    @Test("a hooked pedal has no label and resolves its hook heights from the kind")
    func hookedPedal() throws {
        let pedals = try Self.layout("pedal-lines").filter { $0.kind == .pedal }
        let hooked = try #require(pedals.first { $0.detail?.beginHook == .hook90 && $0.detail?.endHook == .hook90 })
        #expect(hooked.rich == nil)
        #expect(hooked.detail?.endHookHeightSp == 1.2)
        #expect(hooked.detail?.placedBelow == true)
    }

    @Test("<sym> text in a text line, palm mute or let ring is a glyph run, not empty text")
    func symbolLabelsAreGlyphRuns() throws {
        let lines = try Self.layout("line-texts")
        let symbolic = lines.filter { seg in
            Self.contents(seg.rich).contains { if case .symbol = $0 { true } else { false } }
        }
        #expect(symbolic.contains { $0.kind == .textLine })
    }

    @Test("palm mute, let ring and the guitar lines carry their default words; harmonic mark carries none")
    func defaultWords() throws {
        let lines = try Self.layout("line-texts")
        func words(_ kind: LayoutElement.SpannerKind) -> [String] {
            lines.filter { $0.kind == kind && !$0.continuesLeft }.map {
                Self.contents($0.rich).map(\.string).joined()
            }
        }
        #expect(words(.palmMute).contains("P.M."))
        #expect(words(.letRing).contains("let ring"))
        #expect(words(.chordTextLine(.rasgueado)).contains("rasg"))
        #expect(words(.chordTextLine(.pickScrape)).contains("P.S."))
        #expect(words(.chordTextLine(.whammyBar)).contains("w/bar"))
        #expect(words(.chordTextLine(.harmonicMark)) == [""])
    }

    @Test("a text line's continue and end text reach a segment")
    func continueAndEnd() throws {
        let lines = try Self.layout("line-texts", width: 300).filter { $0.kind == .textLine }
        #expect(lines.contains { $0.detail?.endRichText != nil })
        #expect(lines.contains { $0.continuesLeft && !Self.contents($0.rich).isEmpty })
    }

    @Test("a hairpin line shows the authored words, a volta its authored text")
    func hairpinAndVoltaWords() throws {
        let lines = try Self.layout("line-texts")
        let hairpinWords = lines.filter { if case .hairpinLine = $0.kind { true } else { false } }
            .map { Self.contents($0.rich).map(\.string).joined() }
        #expect(hairpinWords.contains("poco a poco cresc."))
        let voltaWords = lines.filter { if case .volta = $0.kind { true } else { false } }
            .map { Self.contents($0.rich).map(\.string).joined() }
        #expect(voltaWords.contains("Last time"))
    }

    /// A pedal's "Ped." is the music font at its full 20 pt (`TextBase::hasSymbolScale` holds for a pedal segment's
    /// text, `textbase.cpp:3425-3435`), twice the 10 pt a text line's `<sym>` gets — MuseScore 4.7.4 draws the
    /// fixture's pedal mark as large as the staff's own glyphs.
    @Test("a pedal's symbol is set at twice a text line's symbol size")
    func pedalSymbolIsFullSize() throws {
        func symbolSize(_ segments: [Seg], _ kind: LayoutElement.SpannerKind) -> CGFloat? {
            segments.first { $0.kind == kind && $0.rich != nil }?.rich?.lines.flatMap(\.runs)
                .first { if case .symbol = $0.content { true } else { false } }?.font.pointSize
        }
        let pedal = try #require(try symbolSize(Self.layout("pedal-lines"), .pedal))
        let textLine = try #require(try symbolSize(Self.layout("line-texts"), .textLine))
        #expect(abs(pedal - 2 * textLine) < 0.001)
    }

    /// MuseScore 4.7.4 draws "w/bar" and "P.S." under the staff and "rasg" over it: the whammy bar's style table has no
    /// placement row (`whammybar.cpp:40-64`), pick scrape reads `palmMutePlacement` and rasgueado
    /// `ottava8VAPlacement` (`pickscrape.cpp:57`, `rasgueado.cpp:57`).
    @Test("whammy bar and pick scrape lie below the staff, rasgueado above")
    func guitarLinePlacement() throws {
        let lines = try Self.layout("line-texts")
        func below(_ line: Spanner.ChordTextLine) -> Bool? {
            lines.first { $0.kind == .chordTextLine(line) }?.detail?.placedBelow
        }
        #expect(below(.whammyBar) == true)
        #expect(below(.pickScrape) == true)
        #expect(below(.rasgueado) == false)
    }
}
