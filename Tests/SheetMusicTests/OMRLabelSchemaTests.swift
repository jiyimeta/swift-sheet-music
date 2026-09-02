#if !os(Android) && !os(WASI)
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

        /// Otherwise-empty labels, for isolating one stream's comparator
        /// without going through `pageLabels`/`WalkedContent`.
        static func emptyLabels() -> OMRPageLabels {
            OMRPageLabels(
                schema: 1,
                page: .init(index: 0, widthPt: 1, heightPt: 1),
                image: .init(file: "x.png", dpi: 300, labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1]),
                glyphs: [], paths: [], beams: [], curves: [], texts: [],
                census: .init(glyphsByClass: [:], texts: 0),
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

        /// An unrecoverable ink bbox must be an EXPLICIT `null` on the wire,
        /// not an omitted key: the plan's consumer is Python, where
        /// `label["bbox_pt"]` raises `KeyError` on an absent key instead of
        /// yielding `None`. The synthesized `encodeIfPresent` would omit it,
        /// so `Glyph` hand-writes `encode(to:)`.
        @Test func missingBBoxIsWrittenAsAnExplicitNull() throws {
            var labels = Self.emptyLabels()
            labels.glyphs = [OMRPageLabels.Glyph(
                className: "noteheadBlack", bboxPt: nil,
                originPt: [10, 20], advancePt: 1, renderedSizePt: 1, fontSizePt: 1,
            )]
            let data = try OMRLabelSchema.encodeCanonical(labels)
            let root = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any],
            )
            let glyph = try #require((root["glyphs"] as? [[String: Any]])?.first)
            // Present AND null — an absent key would fail the first check.
            #expect(glyph.keys.contains("bbox_pt"))
            #expect(glyph["bbox_pt"] is NSNull)
        }

        /// The explicit null must not cost byte stability (gate P3c-G1):
        /// encode → decode → encode is byte-identical, and a nil bbox still
        /// decodes back to nil.
        @Test func missingBBoxSurvivesEncodeDecodeEncodeByteIdentically() throws {
            var labels = Self.emptyLabels()
            labels.glyphs = [OMRPageLabels.Glyph(
                className: "noteheadBlack", bboxPt: nil,
                originPt: [10, 20], advancePt: 1, renderedSizePt: 1, fontSizePt: 1,
            )]
            let data = try OMRLabelSchema.encodeCanonical(labels)
            let decoded = try OMRLabelSchema.decode(data)
            #expect(decoded.glyphs.first?.bboxPt == nil)
            #expect(decoded == OMRLabelSchema.canonicallySorted(labels))
            #expect(try OMRLabelSchema.encodeCanonical(decoded) == data)
        }

        /// Backward compatibility: a label file written BEFORE the explicit
        /// null (key simply absent) must still decode, to nil.
        @Test func anAbsentBBoxKeyStillDecodes() throws {
            let json = """
            {"class":"noteheadBlack","origin_pt":[10,20],"advance_pt":1,
             "rendered_size_pt":1,"font_size_pt":1}
            """
            let glyph = try JSONDecoder().decode(
                OMRPageLabels.Glyph.self, from: #require(json.data(using: .utf8)),
            )
            #expect(glyph.bboxPt == nil)
            #expect(glyph.className == "noteheadBlack")
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

        @Test func quadlessBeamStaysInThePathStreamAsPlainBeamKind() {
            // The degenerate case documented on pathLabels: a `.beam`-kind
            // PathSegment with no fitted BeamQuad is NOT split into the
            // beam stream — it stays a plain "beam"-kind Path.
            let quadlessBeam = PathSegment(
                kind: .beam,
                rect: CGRect(x: 100, y: 440, width: 60, height: 5),
                lineWidth: 0.4, pageIndex: 0, quad: nil,
            )
            let walked = WalkedContent(glyphs: [], texts: [], paths: [quadlessBeam], curves: [])
            let labels = OMRLabelSchema.pageLabels(
                walked: walked, pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            #expect(labels.beams.isEmpty)
            #expect(labels.paths.count == 1)
            #expect(labels.paths[0].kind == "beam")
            #expect(labels.paths[0].rectPt == [100, 440, 160, 445])
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

        // MARK: - Tie-break totality (canonicallySorted must never fall
        // back to input order for two distinct elements).

        @Test func glyphTieBreakOrdersByRemainingFieldsDeterministically() throws {
            // Same originPt, className, bboxPt — differ only in advancePt,
            // a field the primary key + bbox comparison never touch.
            let base = OMRPageLabels.Glyph(
                className: "noteheadBlack", bboxPt: [0, 0, 1, 1],
                originPt: [10, 20], advancePt: 1, renderedSizePt: 1, fontSizePt: 1,
            )
            var lo = base
            lo.advancePt = 1
            var hi = base
            hi.advancePt = 2
            var forward = Self.emptyLabels()
            forward.glyphs = [lo, hi]
            var reversed = Self.emptyLabels()
            reversed.glyphs = [hi, lo]
            #expect(OMRLabelSchema.canonicallySorted(forward).glyphs.map(\.advancePt) == [1, 2])
            #expect(OMRLabelSchema.canonicallySorted(reversed).glyphs.map(\.advancePt) == [1, 2])
            let dataForward = try OMRLabelSchema.encodeCanonical(forward)
            let dataReversed = try OMRLabelSchema.encodeCanonical(reversed)
            #expect(dataForward == dataReversed)
        }

        @Test func beamTieBreakOrdersByRemainingFieldsDeterministically() throws {
            // Same x0/x1/topSlope/topIntercept AND rectPt/lineWidthPt/
            // botSlope — differ only in botIntercept, the last field the
            // old comparator never consulted.
            let base = OMRPageLabels.Beam(
                rectPt: [100, 440, 160, 445], lineWidthPt: 0,
                x0: 100, x1: 160, topSlope: 0.05, topIntercept: 440.5,
                botSlope: 0.05, botIntercept: 438.5,
            )
            var lo = base
            lo.botIntercept = 438.5
            var hi = base
            hi.botIntercept = 439.0
            var forward = Self.emptyLabels()
            forward.beams = [lo, hi]
            var reversed = Self.emptyLabels()
            reversed.beams = [hi, lo]
            #expect(OMRLabelSchema.canonicallySorted(forward).beams.map(\.botIntercept) == [438.5, 439.0])
            #expect(OMRLabelSchema.canonicallySorted(reversed).beams.map(\.botIntercept) == [438.5, 439.0])
            let dataForward = try OMRLabelSchema.encodeCanonical(forward)
            let dataReversed = try OMRLabelSchema.encodeCanonical(reversed)
            #expect(dataForward == dataReversed)
        }

        @Test func curveTieBreakOrdersByBBoxDeterministically() throws {
            // Same leftPt/rightPt (the entire primary key) — differ only
            // in the last bboxPt component, previously never consulted.
            let base = OMRPageLabels.Curve(
                bboxPt: [100, 395, 150, 399],
                leftPt: [100, 396], rightPt: [150, 396],
            )
            var lo = base
            lo.bboxPt = [100, 395, 150, 399]
            var hi = base
            hi.bboxPt = [100, 395, 150, 400]
            var forward = Self.emptyLabels()
            forward.curves = [lo, hi]
            var reversed = Self.emptyLabels()
            reversed.curves = [hi, lo]
            #expect(OMRLabelSchema.canonicallySorted(forward).curves.map(\.bboxPt) == [lo.bboxPt, hi.bboxPt])
            #expect(OMRLabelSchema.canonicallySorted(reversed).curves.map(\.bboxPt) == [lo.bboxPt, hi.bboxPt])
            let dataForward = try OMRLabelSchema.encodeCanonical(forward)
            let dataReversed = try OMRLabelSchema.encodeCanonical(reversed)
            #expect(dataForward == dataReversed)
        }

        @Test func textTieBreakOrdersByRemainingFieldsDeterministically() throws {
            // Same originPt/text/fontName — differ only in fontSizeTf, a
            // field the old comparator never consulted.
            let base = OMRPageLabels.Text(
                text: "la", fontName: "Edwin", fontSizeTf: 40,
                renderedSizePt: 9.5, originPt: [100, 380],
            )
            var lo = base
            lo.fontSizeTf = 40
            var hi = base
            hi.fontSizeTf = 89
            var forward = Self.emptyLabels()
            forward.texts = [lo, hi]
            var reversed = Self.emptyLabels()
            reversed.texts = [hi, lo]
            #expect(OMRLabelSchema.canonicallySorted(forward).texts.map(\.fontSizeTf) == [40, 89])
            #expect(OMRLabelSchema.canonicallySorted(reversed).texts.map(\.fontSizeTf) == [40, 89])
            let dataForward = try OMRLabelSchema.encodeCanonical(forward)
            let dataReversed = try OMRLabelSchema.encodeCanonical(reversed)
            #expect(dataForward == dataReversed)
        }
    }
#endif
