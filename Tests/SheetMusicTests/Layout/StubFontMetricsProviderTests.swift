import Foundation
@testable import SheetMusicLayout
import Testing

@Suite("StubFontMetricsProvider")
struct StubFontMetricsProviderTests {
    private let stub = StubFontMetricsProvider()

    @Test func ascentScalesWithPointSize() {
        let f = LayoutFont(face: "Bravura", pointSize: 4)
        #expect(stub.ascent(font: f) == 4 * 0.85)
    }

    @Test func descentScalesWithPointSize() {
        let f = LayoutFont(face: "Bravura", pointSize: 4)
        #expect(stub.descent(font: f) == 4 * 0.25)
    }

    @Test func glyphPathBoundingBoxReturnsRectangle() {
        let f = LayoutFont(face: "Bravura", pointSize: 4)
        let bbox = stub.glyphPathBoundingBox(font: f, codepoint: 0xE000)
        #expect(bbox == CGRect(x: 0, y: 0, width: 4, height: 4 * 0.7))
    }

    @Test func typographicWidthScalesWithCharCount() {
        let f = LayoutFont(face: "", pointSize: 10, weight: .semibold)
        #expect(stub.typographicWidth(text: "abc", font: f) == 3 * 10 * 0.5)
    }

    @Test func inkBoundsMatchTypographicWidth() {
        let f = LayoutFont(face: "Edwin", pointSize: 12)
        let ink = stub.inkBounds(text: "C", font: f)
        #expect(ink.leftBearing == 0)
        // Uppercase = 0.65 em in the per-class advance table.
        #expect(ink.width == 1 * 12 * 0.65)
    }

    /// The stub has no notion of line gap. Until 4.0.0 this was the protocol's default, which every provider
    /// without its own `leading` inherited.
    @Test func leadingIsZero() {
        let provider: any FontMetricsProvider = stub
        #expect(provider.leading(font: LayoutFont(face: "Edwin", pointSize: 10)) == 0)
    }

    /// Each non-blank line is its horizontal ink over a `-descent ... ascent` band, lines `ascent + descent +
    /// leading` apart, and a blank line still takes its row. Until 4.0.0 this was the protocol's default; the
    /// numbers are the ones that default produced.
    @Test func textInkBoundsStacksEachLinesInkBand() throws {
        let provider: any FontMetricsProvider = stub
        let f = LayoutFont(face: "Edwin", pointSize: 10)
        // ascent 8.5, descent 2.5, stride 11. "Ag" = 0.65 + 0.5 em = 11.5 pt; "C" = 6.5 pt, two rows down.
        let box = try #require(provider.textInkBounds(text: "Ag\n\nC", font: f))
        #expect(abs(box.minX - 0) < 1e-9)
        #expect(abs(box.maxX - 11.5) < 1e-9)
        #expect(abs(box.minY + 24.5) < 1e-9)
        #expect(abs(box.maxY - 8.5) < 1e-9)
    }

    @Test func textInkBoundsOfBlankTextIsNil() {
        let provider: any FontMetricsProvider = stub
        #expect(provider.textInkBounds(text: " \n ", font: LayoutFont(face: "Edwin", pointSize: 10)) == nil)
    }

    @Test func stubIsAFontMetricsProvider() {
        // Type-level sanity — Stub conforms to the protocol it
        // backs. We deliberately do NOT read `FontMetrics.provider`
        // here: other suites may have installed Apple, and mutating
        // the global mid-test would race with parallel layout tests.
        let provider: any FontMetricsProvider = StubFontMetricsProvider()
        #expect(provider is StubFontMetricsProvider)
    }
}
