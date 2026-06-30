#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    struct VibratoGeometryTests {
        // MARK: - Glyph-run geometry

        @Test func glyphCountAndCodepoint() {
            // width=40, advance=8 → fillCount = lrint((40-8)/8) = 4, count = 1+4 = 5
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.codepoint == SMuFLCodepoint.guitarVibratoStroke)
            #expect(run.origins.count == 5)
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
            // width=32, advance=8 → fillCount = lrint((32-8)/8) = 3, count = 1+3 = 4
            let run = SpannerGeometry.vibratoGlyphRun(
                from: CGPoint(x: 10, y: 5),
                to: CGPoint(x: 42, y: 5),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.origins.count == 4)
            #expect(run.origins[0].x == 10)
            #expect(run.origins[1].x == 18)
            #expect(run.origins[2].x == 26)
            #expect(run.origins[3].x == 34)
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

        @Test func shortSpanDrawsOneGlyph() {
            // width == advance → fillCount = lrint((8-8)/8) = 0, count = 1
            // Mirrors MuseScore: start glyph always emitted even for a
            // span equal to or narrower than one advance width.
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 8, y: 0),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.origins.count == 1)
            #expect(run.origins[0].x == 0)
        }

        @Test func tooNarrowLineDrawsOneGlyph() {
            // advance > width → fillCount = 0, count = 1 (start glyph only)
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 5, y: 0),
                type: .guitarVibrato,
                sp: 8,
                advance: 8,
            )
            #expect(run.origins.count == 1)
        }
    }
#endif
