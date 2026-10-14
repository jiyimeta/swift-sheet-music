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

/// A marker is a text in MuseScore — its segno or coda a symbol of that text — so layout typesets every marker's and
/// jump's text and measures, reserves and hit-tests its runs alone, whatever the marker's kind.
@Suite("Navigation marks are their runs")
struct NavigationRunsTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private static let metrics = StaffMetrics(staffSize: 40)
    private static let origin = CGPoint(x: 40, y: 20)

    private static func marker(_ kind: Marker.Kind, _ xmlText: String) -> LayoutElement {
        .marker(
            kind: kind, text: "", origin: origin,
            richText: LayoutRichText(
                marker: RichText(xmlText: xmlText), style: kind.isRightMarker ? .repeatRight : .repeatLeft,
                metrics: metrics,
            ),
        )
    }

    @Test("a marker's ink and skyline box are its runs', whatever its kind", arguments: [
        Marker.Kind.segno, .coda, .codetta, .toCodaSym, .fine, .user,
    ])
    func markerIsItsRuns(kind: Marker.Kind) throws {
        let element = Self.marker(kind, kind == .user ? "Solo" : kind.defaultXMLText)
        guard case let .marker(_, _, origin, _, rich?, _, _) = element else {
            Issue.record("no runs")
            return
        }
        let anchor = LayoutRichText.anchor(for: .forMarker(kind))
        let ink = try #require(TextInkGeometry.rects(for: element, metrics: Self.metrics))
        let expectedInk = try #require(rich.inkRect(at: origin, anchor: anchor))
        #expect(ink == [expectedInk])
        let box = LayoutElementShape.autoplacedRects(for: element, kind: .marker, metrics: Self.metrics)
        #expect(box == [LayoutElementShape.textRect(rich: rich, origin: origin, kind: .forMarker(kind))])
    }

    @Test("a marker or jump without runs has no ink and reserves nothing")
    func noRunsNoInk() {
        let marker = LayoutElement.marker(kind: .fine, text: "Fine", origin: Self.origin)
        let jump = LayoutElement.jump(text: "D.C.", origin: Self.origin)
        #expect(TextInkGeometry.rects(for: marker, metrics: Self.metrics) == [])
        #expect(TextInkGeometry.rects(for: jump, metrics: Self.metrics) == [])
        #expect(LayoutElementShape.autoplacedRects(for: marker, kind: .marker, metrics: Self.metrics).isEmpty)
        #expect(LayoutElementShape.autoplacedRects(for: jump, kind: .jump, metrics: Self.metrics).isEmpty)
    }

    @Test("a mark whose text has no runs reserves nothing, though its LayoutRichText exists")
    func emptyRunsReserveNothing() {
        let element = Self.marker(.user, "")
        #expect(LayoutElementShape.navigationLabelRect(for: element) == nil)
        #expect(LayoutElementShape.autoplacedRects(for: element, kind: .marker, metrics: Self.metrics).isEmpty)
    }

    /// Review Focus 1: what layout hands every renderer — a marker's type default when it has no text, set in
    /// MuseScore's repeat style.
    @Test("layout typesets every mark: a codetta's two codas, a Fine, a bare custom marker, a jump in Edwin")
    func layoutTypesetsEveryMark() throws {
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
        let measure = Measure(
            voices: [Voice(elements: [.chord(chord)])],
            markers: [Marker(kind: .codetta), Marker(kind: .fine), Marker(kind: .user)],
            jumps: [Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")],
        )
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: [measure])],
        )])
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
        let laid = try #require(document.systems.first?.measures.first)
        let contents = laid.markers.map { element -> [LayoutRichTextRun.Content] in
            guard case let .marker(_, _, _, _, rich?, _, _) = element else { return [] }
            return rich.lines.flatMap(\.runs).map(\.content)
        }
        #expect(contents == [[.symbol(codepoint: 0xE048), .symbol(codepoint: 0xE048)], [.text("Fine")], []])
        guard case let .jump(_, _, _, jumpRich?, _, _) = laid.jumps.first else {
            Issue.record("a jump without runs")
            return
        }
        let font = try #require(jumpRich.lines.first?.runs.first?.font)
        let size = 10 * document.metrics.sp / 5
        #expect(font.weight == .regular && !font.isItalic && abs(font.pointSize - size) < 1e-6)
    }
}
