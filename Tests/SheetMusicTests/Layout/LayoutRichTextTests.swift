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

    /// Staff text's symbol size is its text size at the reference spatium, so `symbolRun` cannot tell them apart. Tempo
    /// can: `Sid::tempoMusicalSymbolSize` 20 against `tempoFontSize` 12 (`styledef.cpp:2074, 1149`), both spatium
    /// dependent — at `staffSize: 40` the spatium is 10 pt, twice the reference, so 40 pt and 24 pt.
    @Test("a tempo mark's symbol is Bravura at tempo's musical-symbol size, scaled with the spatium as its text is")
    func tempoSymbolSize() {
        Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.symbol(name: "metNoteQuarterUp", Self.plain), .text(" = 120", Self.plain)]]),
                style: .tempo, metrics: StaffMetrics(staffSize: 40),
            )
            let runs = rich.lines[0].runs
            #expect(runs[0].content == .symbol(codepoint: 0xECA5))
            #expect(runs[0].font == LayoutFont(face: SMuFLFamily.bravura, pointSize: 40))
            #expect(Self.close(runs[1].font.pointSize, 24) && runs[1].font.weight == .bold)
            // The stub advances a private-use codepoint 0.55 em: 0.55 × 40.
            #expect(Self.close(runs[1].x, 22))
        }
    }

    /// A marker's symbols take `Sid::repeatLeft/RightMusicalSymbolSize` (18) scaled by sp / 5, its text the role's
    /// sp × 2.5 — at `staffSize: 40`, 36 pt and 25 pt.
    @Test("a marker's symbol is Bravura at 18 pt per reference spatium")
    func markerSymbolSize() {
        Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.text("To Coda ", Self.plain), .symbol(name: "coda", Self.plain)]]),
                role: .markerText, metrics: StaffMetrics(staffSize: 40),
            )
            let runs = rich.lines[0].runs
            #expect(Self.close(runs[0].font.pointSize, 25))
            #expect(runs[1].content == .symbol(codepoint: 0xE048))
            #expect(runs[1].font == LayoutFont(face: SMuFLFamily.bravura, pointSize: 36))
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
            #expect(runs.map(\.content) == [.text("a"), .symbol(codepoint: 0x20), .text("b")])
            #expect(Self.close(runs[1].x, 5) && Self.close(runs[2].x, 8))
        }
    }

    /// `TextBase::createBlocks` inserts U+0020 under the ScoreText family for `SymId::space`
    /// (`textbase.cpp:1731-1733`), so it advances by the music font's space at the symbol size. At `staffSize: 40` a
    /// tempo's symbols are 40 pt and its text 24 pt; the stub advances a space 0.3 em, so 12 pt in Bravura against
    /// 7.2 pt in the text font.
    @Test("a `space` symbol advances the music font's space at the symbol size, not the text font's")
    func spaceSymbolAdvancesInTheMusicFont() {
        Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[
                    .symbol(name: "metNoteQuarterUp", Self.plain), .symbol(name: "space", Self.plain),
                    .symbol(name: "metAugmentationDot", Self.plain),
                ]]),
                style: .tempo, metrics: StaffMetrics(staffSize: 40),
            )
            let runs = rich.lines[0].runs
            #expect(runs.count == 3)
            let space = runs[1]
            #expect(space.content == .symbol(codepoint: 0x20))
            #expect(space.font == LayoutFont(face: SMuFLFamily.bravura, pointSize: 40))
            let expected = FontMetrics.provider.typographicWidth(text: " ", font: space.font)
            #expect(Self.close(space.advance, expected))
            #expect(Self.close(space.advance, 12))
            #expect(Self.close(runs[2].x, runs[1].x + space.advance))
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

    /// "To Coda " is 3.9 em of 12.5 pt marker text, 48.75; its baseline is the text's ascent, 10.625, and the underline
    /// 0.12 em below it, at 12.125.
    @Test("an underline spans the text runs only, never a symbol")
    func symbolIsNotUnderlined() {
        Self.stub {
            let underlined = RichTextFormat(underline: true)
            let rich = LayoutRichText(
                RichText(lines: [[.text("To Coda ", underlined), .symbol(name: "coda", underlined)]]),
                role: .markerText, metrics: Self.metrics,
            )
            #expect(rich.lines[0].runs.map(\.underline) == [true, false])
            let bars = rich.decorations(at: .zero, anchor: .zero)
            #expect(bars.count == 1)
            #expect(Self.close(bars[0].from.x, 0) && Self.close(bars[0].to.x, 48.75))
            #expect(Self.close(bars[0].from.y, 12.125))
        }
    }

    /// "a" and "b" are 5 pt each and the space 3 between them; the strike sits 0.28 em above the 8.5 pt baseline.
    @Test("MuseScore's `space` symbol is not struck through with the text around it")
    func spaceSymbolIsNotStruck() {
        Self.stub {
            let struck = RichTextFormat(strike: true)
            let rich = Self.staffText([[
                .text("a", struck), .symbol(name: "space", struck), .text("b", struck),
            ]])
            #expect(rich.lines[0].runs.map(\.strike) == [true, false, true])
            let bars = rich.decorations(at: .zero, anchor: .zero)
            #expect(bars.count == 2)
            #expect(Self.close(bars[0].from.x, 0) && Self.close(bars[0].to.x, 5))
            #expect(Self.close(bars[1].from.x, 8) && Self.close(bars[1].to.x, 13))
            #expect(Self.close(bars[1].from.y, 5.7))
        }
    }

    /// "abcd" inks 20 pt and "ab" 10, so the block is 20 wide and the shorter line has 10 to share out; the stack is
    /// 22 high, baselines 8.5 and 19.5 down it.
    @Test("a shorter line is centered or right-aligned against the longest, as the anchor's x says")
    func eachLineAligns() {
        Self.stub {
            let rich = Self.staffText([[.text("abcd", Self.plain)], [.text("ab", Self.plain)]])
            let origin = CGPoint(x: 100, y: 200)
            let centered = rich.positionedRuns(at: origin, anchor: CGPoint(x: 0.5, y: 0.5))
            #expect(Self.close(centered[0].baseline.x, 90) && Self.close(centered[1].baseline.x, 95))
            #expect(Self.close(centered[0].baseline.y, 197.5) && Self.close(centered[1].baseline.y, 208.5))
            let ink = rich.inkRect(at: origin, anchor: CGPoint(x: 0.5, y: 0.5)) ?? .zero
            #expect(Self.close(ink.minX, 90) && Self.close(ink.width, 20) && Self.close(ink.height, 22))
            let right = rich.positionedRuns(at: origin, anchor: CGPoint(x: 1, y: 0.5))
            #expect(Self.close(right[0].baseline.x, 80) && Self.close(right[1].baseline.x, 90))
            let left = rich.positionedRuns(at: origin, anchor: CGPoint(x: 0, y: 1))
            #expect(Self.close(left[0].baseline.x, 100) && Self.close(left[1].baseline.x, 100))
        }
    }

    /// The stub inks a string from its pen even when it opens with a space (`inkBounds` has no left bearing), so only a
    /// space that is a run of its own — which inks nothing — starts a line's ink after its pen: here at 3, the space's
    /// advance, with "pizz." 23 wide.
    @Test("a line whose ink starts after its pen is placed by its ink")
    func leadingSpaceRun() {
        Self.stub {
            let rich = Self.staffText([[.text(" ", Self.plain), .text("pizz.", Self.plain)]])
            #expect(Self.close(rich.ink?.minX ?? -1, 0) && Self.close(rich.ink?.width ?? 0, 23))
            let origin = CGPoint(x: 40, y: 60)
            let leading = rich.positionedRuns(at: origin, anchor: CGPoint(x: 0, y: 1))
            #expect(Self.close(leading[0].baseline.x, 37) && Self.close(leading[1].baseline.x, 40))
            #expect(Self.close(rich.inkRect(at: origin, anchor: CGPoint(x: 0, y: 1))?.minX ?? 0, 40))
            let trailing = rich.positionedRuns(at: origin, anchor: CGPoint(x: 1, y: 1))
            #expect(Self.close(trailing[1].baseline.x, 17))
        }
    }
}
