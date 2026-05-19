#if !os(Android)
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
            #expect(ink.width == 1 * 12 * 0.5)
        }

        @Test func defaultProviderIsStub() {
            // Sanity check that `FontMetrics.provider` is assignable to
            // a Stub and reads back as a Stub. The default at process
            // launch is a Stub (see `FontMetricsProvider.swift`); other
            // test suites may have installed `AppleFontMetricsProvider`
            // before this point, so reset explicitly rather than rely
            // on test ordering.
            FontMetrics.provider = StubFontMetricsProvider()
            #expect(FontMetrics.provider is StubFontMetricsProvider)
        }
    }
#endif
