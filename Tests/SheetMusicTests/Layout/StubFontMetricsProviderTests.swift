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

    @Test func stubIsAFontMetricsProvider() {
        // Type-level sanity — Stub conforms to the protocol it
        // backs. We deliberately do NOT read `FontMetrics.provider`
        // here: other suites may have installed Apple, and mutating
        // the global mid-test would race with parallel layout tests.
        let provider: any FontMetricsProvider = StubFontMetricsProvider()
        #expect(provider is StubFontMetricsProvider)
    }
}
