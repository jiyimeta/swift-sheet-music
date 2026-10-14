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

/// Typesetting against the stub provider, whose metrics are exact: an advance is a fixed share of the em per
/// character (lowercase 0.5, uppercase 0.65, space and punctuation 0.3, anything else 0.55), ascent 0.85 em, descent
/// 0.25 em, no leading, and ink spanning each non-blank run's advance over that band. At `staffSize: 20` the spatium is
/// 5 pt, MuseScore's reference, so a spatium-dependent style's sizes are its literal points.
@Suite("LayoutRichText")
struct LayoutRichTextTests {
    private static let metrics = StaffMetrics(staffSize: 20)
    private static let plain = RichTextFormat()

    private static func stub<T>(_ body: () throws -> T) rethrows -> T {
        try FontMetrics.$scopedProvider.withValue(StubFontMetricsProvider(), operation: body)
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 1e-9
    }

    private static func staffText(_ lines: [[RichTextRun]], metrics: StaffMetrics = metrics) -> LayoutRichText {
        LayoutRichText(RichText(lines: lines), style: .staffText, metrics: metrics)
    }

    @Test("a bold run and a regular one sit side by side on one line")
    func boldThenRegular() {
        Self.stub {
            let rich = Self.staffText([[
                .text("Solo", RichTextFormat(bold: true)), .text(" ad lib.", RichTextFormat(bold: false)),
            ]])
            let runs = rich.lines[0].runs
            #expect(runs.map(\.font.weight) == [.bold, .regular])
            #expect(Self.close(runs[0].x, 0) && Self.close(runs[1].x, 21.5))
            #expect(Self.close(runs[0].advance, 21.5) && Self.close(runs[1].advance, 34))
            #expect(Self.close(rich.size.width, 55.5) && Self.close(rich.size.height, 11))
            let ink = rich.ink ?? .zero
            #expect(Self.close(ink.minX, 0) && Self.close(ink.width, 55.5) && Self.close(ink.height, 11))
        }
    }

    @Test("a symbol is a Bravura glyph at the style's musical-symbol size, never bold or italic")
    func symbolRun() {
        Self.stub {
            let rich = Self.staffText([[
                .text("senza ", Self.plain), .symbol(name: "keyboardPedalPed", Self.plain),
                .symbol(name: "coda", RichTextFormat(bold: true, italic: true)),
            ]])
            let runs = rich.lines[0].runs
            #expect(runs[1].content == .symbol(codepoint: 0xE650))
            #expect(runs[1].font == LayoutFont(face: SMuFLFamily.bravura, pointSize: 10))
            #expect(runs[2].font == LayoutFont(face: SMuFLFamily.bravura, pointSize: 10))
            #expect(Self.close(runs[1].x, 28))
        }
    }

    /// Review Focus 4.
    @Test("a name with no glyph is dropped and MuseScore's `space` symbol advances like a space")
    func unknownSymbolAndSpace() {
        Self.stub {
            let rich = Self.staffText([[
                .text("a", Self.plain), .symbol(name: "noSuchGlyph", Self.plain),
                .symbol(name: "space", Self.plain), .text("b", Self.plain),
            ]])
            let runs = rich.lines[0].runs
            #expect(runs.map(\.content) == [.text("a"), .text(" "), .text("b")])
            #expect(Self.close(runs[1].x, 5) && Self.close(runs[2].x, 8))
        }
    }

    /// Review Focus 3.
    @Test("an empty line keeps its height, so a broken text stacks as plain text does")
    func emptyLineKeepsHeight() {
        Self.stub {
            let rich = Self.staffText([[.text("ab", Self.plain)], [], [.text("cd", Self.plain)]])
            let font = TextInkGeometry.font(for: .staffText, metrics: Self.metrics)
            #expect(rich.lineBaselines.count == 3)
            #expect(Self.close(
                rich.size.height, TextInkGeometry.typographicSize(text: "ab\n\ncd", font: font).height,
            ))
        }
    }

    @Test("one unformatted run measures and places exactly as the plain text does")
    func plainEquivalence() {
        Self.stub {
            let rich = Self.staffText([[.text("pizz.", Self.plain)]])
            let font = TextInkGeometry.font(for: .staffText, metrics: Self.metrics)
            let origin = CGPoint(x: 40, y: 60)
            let anchor = CGPoint(x: 0, y: 1)
            let expected = TextInkGeometry.rect(text: "pizz.", font: font, origin: origin, anchor: anchor) ?? .zero
            let actual = rich.inkRect(at: origin, anchor: anchor) ?? .zero
            #expect(Self.close(actual.minX, expected.minX) && Self.close(actual.minY, expected.minY))
            #expect(Self.close(actual.width, expected.width) && Self.close(actual.height, expected.height))
        }
    }

    @Test("</b> makes a bold style's text regular")
    func closingBoldOnABoldStyle() {
        Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.text("A", Self.plain), .text("b", RichTextFormat(bold: false))]]),
                style: .rehearsalMark, metrics: Self.metrics,
            )
            #expect(rich.lines[0].runs.map(\.font.weight) == [.bold, .regular])
        }
    }

    @Test("<font size> scales with the spatium of a spatium-dependent style")
    func fontSizeScalesWithSpatium() {
        Self.stub {
            let rich = Self.staffText(
                [[.text("x", RichTextFormat(size: 12)), .text("y", Self.plain)]],
                metrics: StaffMetrics(staffSize: 40),
            )
            #expect(rich.lines[0].runs.map(\.font.pointSize) == [24, 20])
        }
    }

    @Test("a script run is 0.6 of the size, shifted by MuseScore's x-height offsets")
    func scripts() {
        Self.stub {
            let rich = Self.staffText([[
                .text("H", Self.plain), .text("2", RichTextFormat(verticalAlign: .subScript)),
                .text("n", RichTextFormat(verticalAlign: .superScript)),
            ]])
            let runs = rich.lines[0].runs
            #expect(Self.close(runs[1].font.pointSize, 6))
            #expect(Self.close(runs[1].baselineShift, 2.4))
            #expect(Self.close(runs[2].baselineShift, -4.32))
        }
    }

    @Test("runs are placed by the block anchor: ink horizontally, the line stack vertically")
    func placement() {
        Self.stub {
            let rich = Self.staffText([[
                .text("Solo", RichTextFormat(bold: true)), .text(" ad lib.", RichTextFormat(bold: false)),
            ]])
            let runs = rich.positionedRuns(at: CGPoint(x: 100, y: 200), anchor: CGPoint(x: 0, y: 1))
            #expect(Self.close(runs[0].baseline.x, 100) && Self.close(runs[1].baseline.x, 121.5))
            #expect(Self.close(runs[0].baseline.y, 197.5) && Self.close(runs[1].baseline.y, 197.5))
        }
    }

    @Test("underline and strike are bars under and through their runs")
    func decorations() {
        Self.stub {
            let struck = RichTextFormat(underline: false, strike: true)
            let rich = LayoutRichText(
                RichText(lines: [[.text("ab", Self.plain), .text("cd", struck)]]),
                baseFont: TextInkGeometry.font(for: .staffText, metrics: Self.metrics),
                pointScale: 1, symbolPointSize: 10, underline: true,
            )
            let bars = rich.decorations(at: .zero, anchor: .zero)
            #expect(bars.count == 2)
            #expect(Self.close(bars[0].from.x, 0) && Self.close(bars[0].to.x, 10) && Self.close(bars[0].from.y, 9.7))
            #expect(Self.close(bars[1].from.x, 10) && Self.close(bars[1].to.x, 20) && Self.close(bars[1].from.y, 5.7))
            #expect(Self.close(bars[0].thickness, 0.6))
        }
    }
}
