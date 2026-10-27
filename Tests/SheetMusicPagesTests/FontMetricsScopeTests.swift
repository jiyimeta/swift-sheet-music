import Foundation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicPages
import Testing

#if !canImport(CoreGraphics)
    // Foundation off Apple ships its own `CGFloat` / `CGRect`; `FontMetricsProvider` speaks SheetMusicLayout's
    // (`CGTypes+Android.swift`), so the providers below name those.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// `FontMetrics.withProvider(_:operation:)`: a provider for one computation, never the process-wide one — how a video
/// lays out with the portable table on Apple while the app's own views keep CoreText.
///
/// Every check reads through `FontMetrics.provider`, as the layout does; none swaps the process-wide provider, which
/// every suite in the test process shares. `SheetMusicPages` is imported without `@testable`, so this suite is also
/// what proves `fontMetricsTableProvider(_:)` is reachable from a host.
@Suite("FontMetrics.withProvider")
struct FontMetricsScopeTests {
    /// The styled table Android and Windows lay out with — the one a video lays out with on every platform.
    private static func tableBytes() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/SheetMusicRenderWindows/Resources/sheet-music.smft")
        return try Data(contentsOf: url)
    }

    /// One treble bar of a whole note under a staff text: a glyph and a text for the layout to measure.
    private static let score = Score(
        division: 480,
        parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
            ])])])],
        )],
        systemMeasures: [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .staffText(StaffText(text: "dolce"))),
        ])],
    )

    private static let probe = LayoutFont(face: "", pointSize: 10)

    private static func answeringFace() -> String {
        FontMetrics.provider.renderingTextFont(probe).face
    }

    @Test("a scope answers every read inside it, an inner scope wins until it ends, and the old provider comes back")
    func aScopeAnswersInsideAndRestoresAfter() {
        let a = SentinelProvider(name: "A")
        let b = SentinelProvider(name: "B")
        FontMetrics.withProvider(a) {
            #expect(Self.answeringFace() == "SENTINEL-A")
            FontMetrics.withProvider(b) {
                #expect(Self.answeringFace() == "SENTINEL-B")
            }
            #expect(Self.answeringFace() == "SENTINEL-A")
        }
        #expect(Self.answeringFace() != "SENTINEL-A")
    }

    @Test("an operation's error passes through, and the scope ends with it")
    func aThrowingOperationEndsTheScope() {
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try FontMetrics.withProvider(SentinelProvider(name: "A")) { () throws in throw Failure() }
        }
        #expect(Self.answeringFace() != "SENTINEL-A")
    }

    @Test("ScorePages lays out with the scope's provider")
    func thePagesLayoutReadsTheScope() throws {
        let counting = try CountingProvider(base: fontMetricsTableProvider(Self.tableBytes()))
        _ = FontMetrics.withProvider(counting) {
            ScorePages.compute(score: Self.score, pageWidthMM: 210, pageHeightMM: 297)
        }
        #expect(counting.reads > 0)
    }
}

/// The stub's measurements under a rendering face that names the provider, so which provider answered can be read off
/// any `renderingTextFont` call.
private struct SentinelProvider: FontMetricsProvider {
    let name: String
    let stub = StubFontMetricsProvider()

    func renderingTextFont(_ font: LayoutFont) -> LayoutFont {
        LayoutFont(face: "SENTINEL-\(name)", pointSize: font.pointSize, weight: font.weight, isItalic: font.isItalic)
    }

    func ascent(font: LayoutFont) -> CGFloat {
        stub.ascent(font: font)
    }

    func descent(font: LayoutFont) -> CGFloat {
        stub.descent(font: font)
    }

    func leading(font: LayoutFont) -> CGFloat {
        stub.leading(font: font)
    }

    func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> CGRect? {
        stub.glyphPathBoundingBox(font: font, codepoint: codepoint)
    }

    func typographicWidth(text: String, font: LayoutFont) -> CGFloat {
        stub.typographicWidth(text: text, font: font)
    }

    func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        stub.inkBounds(text: text, font: font)
    }

    func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
        stub.textInkBounds(text: text, font: font)
    }
}

/// Forwards every requirement to `base` and counts the calls, so a test can tell whether a computation read it.
private final class CountingProvider: FontMetricsProvider, @unchecked Sendable {
    private let base: any FontMetricsProvider
    /// Guards `calls`: a layout may measure from more than one thread.
    private let lock = NSLock()
    private var calls = 0

    init(base: any FontMetricsProvider) {
        self.base = base
    }

    /// How many requirements were called so far.
    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func counted<Answer>(_ answer: () -> Answer) -> Answer {
        lock.lock()
        calls += 1
        lock.unlock()
        return answer()
    }

    func ascent(font: LayoutFont) -> CGFloat {
        counted { base.ascent(font: font) }
    }

    func descent(font: LayoutFont) -> CGFloat {
        counted { base.descent(font: font) }
    }

    func leading(font: LayoutFont) -> CGFloat {
        counted { base.leading(font: font) }
    }

    func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> CGRect? {
        counted { base.glyphPathBoundingBox(font: font, codepoint: codepoint) }
    }

    func typographicWidth(text: String, font: LayoutFont) -> CGFloat {
        counted { base.typographicWidth(text: text, font: font) }
    }

    func caretOffsets(text: String, font: LayoutFont) -> [CGFloat] {
        counted { base.caretOffsets(text: text, font: font) }
    }

    func selectionOffsets(text: String, font: LayoutFont, range: Range<Int>) -> [ClosedRange<CGFloat>] {
        counted { base.selectionOffsets(text: text, font: font, range: range) }
    }

    func characterIndex(forOffset offset: CGFloat, text: String, font: LayoutFont) -> Int {
        counted { base.characterIndex(forOffset: offset, text: text, font: font) }
    }

    func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        counted { base.inkBounds(text: text, font: font) }
    }

    func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
        counted { base.textInkBounds(text: text, font: font) }
    }

    func renderingTextFont(_ font: LayoutFont) -> LayoutFont {
        counted { base.renderingTextFont(font) }
    }
}
