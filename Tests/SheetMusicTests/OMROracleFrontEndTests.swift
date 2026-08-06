#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct OMROracleFrontEndTests {
        @Test func replayReconstructsEveryStreamExactly() throws {
            let content = OMRLabelSchemaTests.sampleContent()
            let labels = OMRLabelSchema.pageLabels(
                walked: content, pageIndex: 0,
                pageSize: CGSize(width: 595.276, height: 841.89), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            // Serialize + reparse first, so the test covers the full
            // labels-on-disk path, not just the in-memory value.
            let reparsed = try OMRLabelSchema.decode(OMRLabelSchema.encodeCanonical(labels))
            let replay = try OMROracleFrontEnd.replay(pages: [reparsed])

            #expect(replay.pageCount == 1)
            #expect(replay.pageSizes[0] == CGSize(width: 595.276, height: 841.89))
            // Streams compare against the CANONICALLY SORTED original,
            // since labels are written in canonical order.
            let sortedRef = try OMROracleFrontEnd.replay(
                pages: [OMRLabelSchema.canonicallySorted(labels)],
            )
            #expect(replay.walked.glyphs == sortedRef.walked.glyphs)
            #expect(replay.walked.paths == sortedRef.walked.paths)
            #expect(replay.walked.curves == sortedRef.walked.curves)
            // Set-level equality against the ORIGINAL content proves no
            // glyph/path/curve was lost or altered by the round trip.
            #expect(Set(replay.walked.glyphs) == Set(content.glyphs))
            #expect(replay.walked.paths.count == content.paths.count)
            #expect(replay.walked.curves == content.curves)
            // TextGlyph has no Equatable conformance — compare fields.
            #expect(replay.walked.texts.count == 1)
            let t = try #require(replay.walked.texts.first)
            #expect(t.text == "la")
            #expect(t.fontName == "Edwin")
            #expect(t.fontSize == 89)
            #expect(t.renderedSize == 9.5)
            #expect(t.origin == CGPoint(x: 100, y: 380))
            #expect(t.bbox == .zero)
            #expect(t.pageIndex == 0)
        }

        @Test func beamQuadIsRebuiltFromTheBeamStream() throws {
            let labels = OMRLabelSchema.pageLabels(
                walked: OMRLabelSchemaTests.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            let replay = try OMROracleFrontEnd.replay(pages: [labels])
            let beam = try #require(replay.walked.paths.first { $0.kind == .beam })
            let quad = try #require(beam.quad)
            #expect(quad.xRange == 100 ... 160)
            #expect(quad.topIntercept == 440.5)
            #expect(quad.botIntercept == 438.5)
            #expect(quad.pageIndex == 0)
        }

        @Test func fontSizeSurvivesForOracleLosslessness() throws {
            let labels = OMRLabelSchema.pageLabels(
                walked: OMRLabelSchemaTests.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            let replay = try OMROracleFrontEnd.replay(pages: [labels])
            #expect(replay.walked.glyphs.allSatisfy { $0.geometry.fontSize == 100 })
        }

        @Test func multiPageReplayIndexesPagesCorrectly() throws {
            let content = OMRLabelSchemaTests.sampleContent()
            let page0 = OMRLabelSchema.pageLabels(
                walked: content, pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            var shifted = content
            for i in shifted.glyphs.indices {
                shifted.glyphs[i].geometry.pageIndex = 1
            }
            for i in shifted.paths.indices {
                shifted.paths[i].pageIndex = 1
            }
            for i in shifted.curves.indices {
                shifted.curves[i].pageIndex = 1
            }
            for i in shifted.texts.indices {
                shifted.texts[i].pageIndex = 1
            }
            let page1 = OMRLabelSchema.pageLabels(
                walked: shifted, pageIndex: 1,
                pageSize: CGSize(width: 612, height: 792), dpi: 300,
                imageFile: "page_1.png", inkBBox: { _ in nil },
            )
            // Deliberately unsorted page list: replay must sort by index.
            let replay = try OMROracleFrontEnd.replay(pages: [page1, page0])
            #expect(replay.pageCount == 2)
            #expect(replay.pageSizes[1] == CGSize(width: 612, height: 792))
            #expect(replay.walked.glyphs.contains { $0.geometry.pageIndex == 1 })
            #expect(replay.walked.glyphs.contains { $0.geometry.pageIndex == 0 })
        }

        @Test func unknownClassNameThrows() {
            var labels = OMRLabelSchema.pageLabels(
                walked: OMRLabelSchemaTests.sampleContent(), pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            labels.glyphs[0].className = "notAClass"
            #expect(throws: SheetMusicError.self) {
                _ = try OMROracleFrontEnd.replay(pages: [labels])
            }
        }
    }
#endif
