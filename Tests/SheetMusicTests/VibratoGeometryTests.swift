#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    struct VibratoGeometryTests {
        // MARK: - Glyph-run geometry

        @Test func glyphCountAndCodepoint() {
            // width=40, advance=8 → count = lrint((40-8)/8) = 4
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.codepoint == SMuFLCodepoint.guitarVibratoStroke)
            #expect(run.origins.count == 4)
        }

        @Test func sawtoothUsesWiggleGlyph() {
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: .sawtooth,
                sp: 8,
                advance: 8,
            )
            #expect(run.codepoint == SMuFLCodepoint.wiggleSawtooth)
        }

        @Test func sawtoothWideUsesWiggleWideGlyph() {
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: .sawtoothWide,
                sp: 8,
                advance: 8,
            )
            #expect(run.codepoint == SMuFLCodepoint.wiggleSawtoothWide)
        }

        @Test func guitarVibratoWideUsesWideStroke() {
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: .guitarVibratoWide,
                sp: 8,
                advance: 8,
            )
            #expect(run.codepoint == SMuFLCodepoint.guitarWideVibratoStroke)
        }

        @Test func originsAreEvenlySpaced() {
            // width=32, advance=8 → count = lrint((32-8)/8) = 3
            let run = SpannerGeometry.vibratoGlyphRun(
                from: CGPoint(x: 10, y: 5),
                to: CGPoint(x: 42, y: 5),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.origins.count == 3)
            #expect(run.origins[0].x == 10)
            #expect(run.origins[1].x == 18)
            #expect(run.origins[2].x == 26)
            // Y is constant at from.y
            for origin in run.origins {
                #expect(origin.y == 5)
            }
        }

        @Test func zeroAdvanceReturnsEmpty() {
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: .guitarVibrato,
                sp: 8,
                advance: 0,
            )
            #expect(run.origins.isEmpty)
        }

        @Test func tooNarrowLineReturnsEmpty() {
            // advance >= width → count ≤ 0
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 5, y: 0),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.origins.isEmpty)
        }
    }
#endif
