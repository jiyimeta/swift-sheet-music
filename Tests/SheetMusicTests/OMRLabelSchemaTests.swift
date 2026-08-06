#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct OMRLabelSchemaTests {
        /// A small but stream-complete WalkedContent: 2 glyphs, 3 paths
        /// (incl. one beam with a quad), 1 curve, 1 text.
        static func sampleContent() -> WalkedContent {
            let g1 = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 100.125, y: 400.0625), advance: 5.5,
                    renderedSize: 10.25, pageIndex: 0, fontSize: 100,
                ),
                semantic: .noteheadBlack,
            )
            let g2 = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 55, y: 416), advance: 5.5,
                    renderedSize: 32, pageIndex: 0, fontSize: 100,
                ),
                semantic: .clefG,
            )
            let staffLine = PathSegment(
                kind: .horizontal,
                rect: CGRect(x: 50, y: 400, width: 400, height: 0),
                lineWidth: 0.6, pageIndex: 0, quad: nil,
            )
            let barline = PathSegment(
                kind: .vertical,
                rect: CGRect(x: 449, y: 400, width: 0, height: 32),
                lineWidth: 1.2, pageIndex: 0, quad: nil,
            )
            let beam = PathSegment(
                kind: .beam,
                rect: CGRect(x: 100, y: 440, width: 60, height: 5),
                lineWidth: 0, pageIndex: 0,
                quad: BeamQuad(
                    xRange: 100 ... 160,
                    topSlope: 0.05, topIntercept: 440.5,
                    botSlope: 0.05, botIntercept: 438.5,
                    pageIndex: 0,
                ),
            )
            let curve = CurveArc(
                bbox: CGRect(x: 100, y: 395, width: 50, height: 4),
                leftPoint: CGPoint(x: 100, y: 396),
                rightPoint: CGPoint(x: 150, y: 396),
                pageIndex: 0,
            )
            let text = TextGlyph(
                text: "la", fontName: "Edwin", fontSize: 89,
                renderedSize: 9.5, origin: CGPoint(x: 100, y: 380),
                bbox: .zero, pageIndex: 0,
            )
            return WalkedContent(
                glyphs: [g1, g2], texts: [text],
                paths: [staffLine, barline, beam], curves: [curve],
            )
        }

        @Test func encodeDecodeRoundTripIsExact() throws {
            let labels = OMRLabelSchema.pageLabels(
                walked: Self.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595.276, height: 841.89), dpi: 300,
                imageFile: "page_0.png",
                inkBBox: { _ in CGRect(x: 1.0625, y: 2.125, width: 3.25, height: 4.5) },
            )
            let data = try OMRLabelSchema.encodeCanonical(labels)
            let decoded = try OMRLabelSchema.decode(data)
            #expect(decoded == OMRLabelSchema.canonicallySorted(labels))
            // Encode again: canonical encode of the decoded value must be
            // byte-identical (idempotence = run-twice stability, P0-G2 at
            // the codec level).
            let data2 = try OMRLabelSchema.encodeCanonical(decoded)
            #expect(data == data2)
        }

        @Test func doublesSurviveExactly() throws {
            // A value with no short decimal representation.
            let ugly = 400.0 + 1.0 / 3.0
            var labels = OMRLabelSchema.pageLabels(
                walked: WalkedContent(glyphs: [], texts: [], paths: [], curves: []),
                pageIndex: 0, pageSize: CGSize(width: ugly, height: 841.89),
                dpi: 300, imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            labels.image.labelTransform = [1, 0, 0, 0, 1, 0, 0, 0, 1]
            let decoded = try OMRLabelSchema.decode(OMRLabelSchema.encodeCanonical(labels))
            #expect(decoded.page.widthPt == ugly) // bit-exact
        }

        @Test func canonicalOrderSortsGlyphsTopDownLeftRight() {
            var labels = OMRLabelSchema.pageLabels(
                walked: Self.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            labels.glyphs.reverse()
            let sorted = OMRLabelSchema.canonicallySorted(labels)
            // clefG at y=416 comes before noteheadBlack at y≈400 (y DESC).
            #expect(sorted.glyphs.first?.className == "clefG")
            #expect(sorted.glyphs.last?.className == "noteheadBlack")
        }

        @Test func censusCoversEveryDetectorClassIncludingZeros() {
            let labels = OMRLabelSchema.pageLabels(
                walked: Self.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            #expect(labels.census.glyphsByClass.count >= 64)
            #expect(labels.census.glyphsByClass["noteheadBlack"] == 1)
            #expect(labels.census.glyphsByClass["clefG"] == 1)
            #expect(labels.census.glyphsByClass["clefF"] == 0)
            #expect(labels.census.texts == 1)
        }

        @Test func beamQuadSurvivesTheBeamStream() {
            let labels = OMRLabelSchema.pageLabels(
                walked: Self.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            #expect(labels.beams.count == 1)
            #expect(labels.paths.count == 2) // beam moved to its own stream
            #expect(labels.beams[0].topIntercept == 440.5)
            #expect(labels.beams[0].rectPt == [100, 440, 160, 445])
        }

        @Test func snakeCaseKeysOnTheWire() throws {
            // NB: pageIndex must match sampleContent()'s tagged pageIndex
            // (0) — pageLabels filters walked.* by pageIndex, and this
            // test is about wire key naming, not page-filtering, so it
            // needs non-empty streams to observe per-element keys.
            let labels = OMRLabelSchema.pageLabels(
                walked: Self.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_3.png", inkBBox: { _ in nil },
            )
            let text = try #require(String(data: OMRLabelSchema.encodeCanonical(labels), encoding: .utf8))
            #expect(text.contains("\"rendered_size_pt\""))
            #expect(text.contains("\"label_transform\""))
            #expect(text.contains("\"class\""))
            #expect(text.contains("\"font_size_pt\""))
            #expect(!text.contains("renderedSizePt")) // no camelCase leaks
        }
    }
#endif
