#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// Element kinds whose runs ride on another kind's layout or are overridden by a glyph.
///
/// A swing marking and an instrument change are model elements of their own that print as staff text
/// (`LayoutEngine+Placement`), so they carry their runs on the `.staffText` they lay out as, in their own style. Every
/// marker draws its runs, a segno or coda included. Measured with the installed provider
/// (`LayoutEngine.layout` asserts it is not the stub), so the checks are relations.
@Suite("Rich text on swing markings, instrument changes and markers")
struct RichTextElementKindTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// "Swing " and the keyboard-pedal glyph: a symbol run inks where no plain text does, whatever the provider.
    static let swingMarkup = PreservedTextMarkup(
        content: [.characters("Swing "), .element(.init(name: "sym", content: [.characters("keyboardPedalPed")]))],
        derivedText: "Swing ",
    )

    static let changeMarkup = PreservedTextMarkup(
        content: [.element(.init(name: "b", content: [.characters("To Flute")]))], derivedText: "To Flute",
    )

    private static func layout(_ element: SystemElement) -> LayoutDocument {
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
        )], systemMeasures: [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: element, originalStaff: staff),
        ])])
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
    }

    private struct Found {
        let element: LayoutElement
        let origin: CGPoint
        let style: TextStyleType
        let rich: LayoutRichText?
    }

    /// The document's one staff-text element.
    private static func staffText(in document: LayoutDocument) -> Found? {
        for element in document.systems.flatMap(\.measures).flatMap(\.elements) {
            if case let .staffText(_, origin, _, style, _, _, _, _, rich) = element {
                return Found(element: element, origin: origin, style: style, rich: rich)
            }
        }
        return nil
    }

    /// The element's ink is its runs' ink, hung bottom-leading off its origin as any staff text's is.
    private static func expectInkFollowsRuns(_ found: Found, metrics: StaffMetrics) throws {
        let rich = try #require(found.rich)
        let ink = try #require(TextInkGeometry.rects(for: found.element, metrics: metrics)?.first)
        let expected = try #require(rich.inkRect(at: found.origin, anchor: CGPoint(x: 0, y: 1)))
        #expect(abs(ink.minX - expected.minX) < 1e-6 && abs(ink.width - expected.width) < 1e-6)
        #expect(abs(ink.minY - expected.minY) < 1e-6 && abs(ink.height - expected.height) < 1e-6)
    }

    @Test("a swing marking lays out its runs, symbol included, as the system text it prints as")
    func swingCarriesRuns() throws {
        let document = Self.layout(.swing(Swing(text: "Swing ", preservedTextMarkup: Self.swingMarkup)))
        let found = try #require(Self.staffText(in: document))
        #expect(found.style == .systemText)
        let runs = try #require(found.rich?.lines.first?.runs)
        #expect(runs.map(\.content) == [.text("Swing "), .symbol(codepoint: 0xE650)])
        try Self.expectInkFollowsRuns(found, metrics: document.metrics)
        // The glyph inks past the text run, so the element's ink is wider than the plain text's alone.
        let ink = try #require(TextInkGeometry.rects(for: found.element, metrics: document.metrics)?.first)
        let textInk = try #require(FontMetrics.provider.textInkBounds(text: "Swing ", font: runs[0].font))
        #expect(ink.width > textInk.width + 1e-6)
    }

    @Test("an instrument change lays out its runs in the instrument-change style")
    func instrumentChangeCarriesRuns() throws {
        let document = Self.layout(.instrumentChange(
            InstrumentChange(text: "To Flute", preservedTextMarkup: Self.changeMarkup),
        ))
        let found = try #require(Self.staffText(in: document))
        #expect(found.style == .instrumentChange)
        let runs = try #require(found.rich?.lines.first?.runs)
        #expect(runs.map(\.content) == [.text("To Flute")])
        #expect(runs.map(\.font.weight) == [.bold])
        try Self.expectInkFollowsRuns(found, metrics: document.metrics)
    }

    /// The control for both: the same markup over edited text lays out plain, so the runs above come from the markup
    /// being current, not from the element kind.
    @Test("edited away from their markup, a swing marking and an instrument change lay out plain")
    func editedIsPlain() throws {
        let swing = Self.layout(.swing(Swing(text: "Shuffle", preservedTextMarkup: Self.swingMarkup)))
        let change = Self.layout(.instrumentChange(
            InstrumentChange(text: "To Oboe", preservedTextMarkup: Self.changeMarkup),
        ))
        for document in [swing, change] {
            let found = try #require(Self.staffText(in: document))
            #expect(found.rich == nil)
        }
    }

    /// Every marker draws its runs — a segno or coda is a symbol run of its text, as in MuseScore — so its skyline box
    /// is its runs' box whatever its kind, and a marker without runs reserves nothing.
    @Test("a marker's skyline box is its runs' box, whatever its kind")
    func markerSkylineIsItsRuns() {
        let metrics = StaffMetrics(staffSize: 20)
        let origin = CGPoint(x: 40, y: 20)
        let coda = LayoutRichText(
            marker: RichText(lines: [[.symbol(name: "coda", RichTextFormat())]]), style: .repeatLeft, metrics: metrics,
        )
        func boxes(_ kind: Marker.Kind, _ rich: LayoutRichText?) -> [CGRect] {
            LayoutElementShape.autoplacedRects(
                for: .marker(kind: kind, text: "", origin: origin, richText: rich), kind: .marker, metrics: metrics,
            )
        }
        #expect(boxes(.coda, coda) == boxes(.user, coda))
        #expect((boxes(.coda, coda).first?.width ?? 0) > 0)
        #expect(boxes(.coda, nil).isEmpty)
    }
}
