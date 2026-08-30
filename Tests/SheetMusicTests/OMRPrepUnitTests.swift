#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct OMRTilingTests {
        @Test func aPageShorterThanOneTileIsASingleTile() {
            #expect(OMRTiling.origins(extent: 200, tile: 384, overlap: 64) == [0])
        }

        @Test func tilesStepByTileMinusOverlapAndTheLastOneIsFlushRight() {
            // step = 320; 0, 320, 640 would run past 900, so the last
            // origin is clamped flush to the right edge instead of
            // producing a short tile the model was never trained on.
            #expect(
                OMRTiling.origins(extent: 900, tile: 384, overlap: 64)
                    == [0, 320, 516],
            )
        }

        @Test func anExactFitDoesNotRepeatTheLastTile() {
            #expect(OMRTiling.origins(extent: 384, tile: 384, overlap: 64) == [0])
            #expect(
                OMRTiling.origins(extent: 704, tile: 384, overlap: 64)
                    == [0, 320],
            )
        }

        @Test func coreRegionsPartitionThePageExactly() {
            let extent = 900, tile = 384, overlap = 64
            let origins = OMRTiling.origins(extent: extent, tile: tile, overlap: overlap)
            let ranges = origins
                .map { OMRTiling.coreRange(origin: $0, extent: extent, tile: tile, overlap: overlap) }
            // Every pixel column belongs to exactly one tile's core, so a
            // detection is claimed once and only once.
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == extent)
            for (a, b) in zip(ranges, ranges.dropFirst()) {
                #expect(a.upperBound == b.lowerBound)
            }
            // Contiguity and total span alone do not prove a core stays
            // INSIDE its own tile's raw window `[origin, origin+tile)` —
            // e.g. `coreRange` returning `[0,300)/[300,600)/[600,900)`
            // for these origins `[0,320,516]` would satisfy every check
            // above while assigning tile 1 (window `[320,704)`) pixels
            // `[300,320)` it never actually rendered. The first/last
            // tiles are naturally flush with the page edge (`lowerBound
            // == 0`, `upperBound == extent`), which the containment
            // check already covers without a separate exception.
            for (origin, range) in zip(origins, ranges) {
                #expect(range.lowerBound >= origin)
                #expect(range.upperBound <= origin + tile)
            }
        }
    }

    struct OMRPrepNormalizeTests {
        @Test func halvingTheStaffSpaceHalvesThePage() throws {
            let page = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 300, dpi: 300, topY: 100, spacingPx: 16,
            )
            let out = try #require(OMRPrepNormalize.normalize(
                page, staffSpacingPx: 16, targetStaffSpacePx: 8,
            ))
            #expect(abs(out.scale - 0.5) < 1e-12)
            #expect(out.bitmap.width == 200)
            #expect(out.bitmap.height == 150)
        }

        @Test func anAlreadyCanonicalPageIsReturnedUnchanged() throws {
            let page = RasterTestBitmaps.staff(
                widthPx: 120, heightPx: 90, dpi: 300, topY: 30, spacingPx: 12,
            )
            let out = try #require(OMRPrepNormalize.normalize(
                page, staffSpacingPx: 12, targetStaffSpacePx: 12,
            ))
            #expect(out.scale == 1.0)
            // Byte-identical, not merely same-sized: scale 1 must not
            // round-trip the page through a resampler that softens ink.
            #expect(out.bitmap.pixels == page.pixels)
        }

        @Test func theStaffStaysWhereTheScaleSaysItShould() throws {
            let page = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 400, dpi: 300, topY: 100, spacingPx: 16,
            )
            let out = try #require(OMRPrepNormalize.normalize(
                page, staffSpacingPx: 16, targetStaffSpacePx: 8,
            ))
            // The top staff line was at y=100; at scale 0.5 its darkest
            // row must be at 50 ± 1.
            let darkest = (0 ..< out.bitmap.height).min {
                rowInk(out.bitmap, $0) < rowInk(out.bitmap, $1)
            }
            #expect(abs((darkest ?? -1) - 50) <= 1)
        }

        @Test func aPageWithNoStaffCannotBeNormalized() {
            let blank = RasterTestBitmaps.blank(widthPx: 40, heightPx: 40, dpi: 300)
            #expect(OMRPrepNormalize.normalize(
                blank, staffSpacingPx: 0, targetStaffSpacePx: 12,
            ) == nil)
        }

        private func rowInk(_ bitmap: GrayBitmap, _ y: Int) -> Int {
            (0 ..< bitmap.width).reduce(0) { $0 + Int(bitmap[$1, y]) }
        }
    }

    struct OMRPrepTargetsTests {
        /// A clean, unskewed page at 300dpi, 100pt tall, scale 1: a glyph
        /// whose origin is at (36pt, 72pt) in y-UP page space must land at
        /// y-DOWN normalized pixel (150, 117), because 36pt = 150px and
        /// the page is 100pt = 417px tall (417 - 300 = 117).
        @Test func aCleanPageMapsPointsToPixelsWithTheYFlip() throws {
            let page = OMRPrepTestPages.clean(widthPt: 200, heightPt: 100, dpi: 300)
            let transform = PageTransform(
                dpi: 300, widthPx: 833, heightPx: 417, deskewDegrees: 0,
            )
            let out = OMRPrepTargets.glyphs(page: page, transform: transform, scale: 1)
            let glyph = try #require(out.glyphs.first)
            #expect(abs(glyph.originPx[0] - 150) < 0.5)
            #expect(abs(glyph.originPx[1] - 117) < 0.5)
        }

        @Test func theScaleFactorMultipliesEveryLength() throws {
            let page = OMRPrepTestPages.clean(widthPt: 200, heightPt: 100, dpi: 300)
            let transform = PageTransform(
                dpi: 300, widthPx: 833, heightPx: 417, deskewDegrees: 0,
            )
            let one = OMRPrepTargets.glyphs(page: page, transform: transform, scale: 1)
            let half = OMRPrepTargets.glyphs(page: page, transform: transform, scale: 0.5)
            let a = try #require(one.glyphs.first), b = try #require(half.glyphs.first)
            #expect(abs(b.originPx[0] - a.originPx[0] / 2) < 1e-9)
            #expect(abs(b.advancePx - a.advancePx / 2) < 1e-9)
            #expect(abs(b.renderedSizePx - a.renderedSizePx / 2) < 1e-9)
        }

        /// On a CLEAN page (identity `labelTransform`), `advancePx`/
        /// `renderedSizePx` computed straight from `advancePt`/
        /// `renderedSizePt * dpi/72 * scale` happens to agree with the
        /// length between the MAPPED bbox corners, because the map is the
        /// identity. `Training/generate/profiles/scanner.toml`'s
        /// `resample` stage (`scale_lo`/`scale_hi`) puts a genuine scale
        /// into a degraded page's `label_transform`, which
        /// `centerPx`/`originPx` absorb (they go through `pointMap`) but
        /// the old `advancePx`/`renderedSizePx` formula did not — a
        /// systematic geometry-target error on every glyph of a degraded
        /// page. This pins the two lengths to the MAPPED corners under a
        /// non-identity transform, so it fails against the old formula
        /// and passes against the fix (which derives them from the same
        /// `a`/`b` corners `centerPx` already uses).
        @Test func lengthsAgreeWithTheMappedCornersUnderADegradedTransform() throws {
            let widthPt = 200.0, heightPt = 100.0, dpi = 300.0
            let box: [Double] = [36, 68, 48, 76]
            let glyph = OMRPageLabels.Glyph(
                className: "noteheadBlack", bboxPt: box,
                originPt: [36, 72], advancePt: 12, renderedSizePt: 8, fontSizePt: 0,
            )
            let scaleH = 1.1
            let page = OMRPageLabels(
                schema: 1,
                page: .init(index: 0, widthPt: widthPt, heightPt: heightPt),
                image: .init(
                    file: "page.png", dpi: Int(dpi),
                    labelTransform: [scaleH, 0, 0, 0, scaleH, 0, 0, 0, 1],
                    sourceSizePx: nil,
                ),
                glyphs: [glyph], paths: [], beams: [], curves: [], texts: [],
                census: .init(glyphsByClass: ["noteheadBlack": 1], texts: 0),
            )
            let transform = PageTransform(
                dpi: dpi,
                widthPx: Int((widthPt * dpi / 72.0 * scaleH).rounded()),
                heightPx: Int((heightPt * dpi / 72.0 * scaleH).rounded()),
                deskewDegrees: 0,
            )

            let out = OMRPrepTargets.glyphs(page: page, transform: transform, scale: 1)
            let g = try #require(out.glyphs.first)

            // Independently recompute the mapped bbox corners through the
            // SAME shared `pointMap` primitive `OMRPrepTargets.glyphs`
            // uses internally, then derive the expected lengths from
            // them exactly as the fix does.
            let map = OMRHybridFrontEnd.pointMap(page: page, transform: transform)
            let perPoint = transform.dpi / 72.0
            let mappedA = map(CGPoint(x: box[0], y: box[1]))
            let mappedB = map(CGPoint(x: box[2], y: box[3]))
            let ax = Double(mappedA.x) * perPoint
            let ay = Double(transform.heightPx) - Double(mappedA.y) * perPoint
            let bx = Double(mappedB.x) * perPoint
            let by = Double(transform.heightPx) - Double(mappedB.y) * perPoint
            let expectedAdvance = abs(bx - ax)
            let expectedRenderedSize = abs(by - ay)

            #expect(abs(g.advancePx - expectedAdvance) < 1e-6)
            #expect(abs(g.renderedSizePx - expectedRenderedSize) < 1e-6)

            // And the OLD formula must NOT agree here — proving the
            // transform's scale is genuinely exercised by this fixture,
            // not coincidentally equal to the fix's answer.
            let oldFormulaAdvance = 12.0 * dpi / 72.0 // advancePt * dpi/72 * scale(1)
            #expect(abs(expectedAdvance - oldFormulaAdvance) > 0.5)
        }

        @Test func theCenterIsTheInkBoxCenterNotTheOrigin() throws {
            let page = OMRPrepTestPages.clean(widthPt: 200, heightPt: 100, dpi: 300)
            let transform = PageTransform(
                dpi: 300, widthPx: 833, heightPx: 417, deskewDegrees: 0,
            )
            let glyph = try #require(
                OMRPrepTargets.glyphs(page: page, transform: transform, scale: 1)
                    .glyphs.first,
            )
            #expect(glyph.centerPx != glyph.originPx)
        }

        @Test func aGlyphWithNoInkBoxIsDroppedAndCounted() {
            let page = OMRPrepTestPages.cleanWithBBoxlessGlyph(
                widthPt: 200, heightPt: 100, dpi: 300,
            )
            let transform = PageTransform(
                dpi: 300, widthPx: 833, heightPx: 417, deskewDegrees: 0,
            )
            let out = OMRPrepTargets.glyphs(page: page, transform: transform, scale: 1)
            #expect(out.droppedNoBBox == 1)
            #expect(out.glyphs.isEmpty)
        }

        @Test func classesOutsideTheDetectorVocabularyAreExcluded() {
            // staff5Lines, stem, restOther and unknown* must never become
            // a target: the first two are P3b's, and the last two cannot
            // be turned back into a SMuFLSemantic at all.
            let page = OMRPrepTestPages.cleanWithClasses(
                ["staff5Lines", "stem", "restOther", "unknownE500", "fine"],
                widthPt: 200, heightPt: 100, dpi: 300,
            )
            let transform = PageTransform(
                dpi: 300, widthPx: 833, heightPx: 417, deskewDegrees: 0,
            )
            let out = OMRPrepTargets.glyphs(page: page, transform: transform, scale: 1)
            #expect(out.glyphs.isEmpty)
        }

        @Test func vocabularyIsReachableFromSourcesAndStillFrozen() {
            let table = OMRGlyphVocabulary.trainable
            #expect(table.count == 62)
            #expect(table.first == "brace")
            #expect(table.last == "ornament")
            // Hand-pasting 62 entries can duplicate one and drop another while
            // keeping the count right; a Set comparison catches exactly that.
            #expect(Set(table).count == table.count, "the table has a duplicate entry")
            // Spot-check interior indices, because count/first/last are all blind
            // to a reordering in the middle — and the class INDEX is what the
            // model's output means. `checkVocabulary` (Task 4) pins the full order;
            // these catch a bad paste here, before that gate exists.
            #expect(table[4] == "noteheadBlack")
            #expect(table[24] == "clefG")
            #expect(table[41] == "timeSig0")
            // The map is what turns a class index into a score element; a
            // missing entry is a glyph silently dropped at classify time.
            for name in table {
                #expect(OMRGlyphVocabulary.semantic(forClassName: name) != nil, "no semantic for \(name)")
            }
        }
    }

    /// Fixture builder for `OMRPrepTargetsTests`: clean (unskewed, identity
    /// `label_transform`) `OMRPageLabels` pages carrying one or more glyphs.
    enum OMRPrepTestPages {
        static func clean(widthPt: Double, heightPt: Double, dpi: Int) -> OMRPageLabels {
            page(widthPt: widthPt, heightPt: heightPt, dpi: dpi, glyphs: [noteheadBlackGlyph()])
        }

        static func cleanWithBBoxlessGlyph(
            widthPt: Double, heightPt: Double, dpi: Int,
        ) -> OMRPageLabels {
            var glyph = noteheadBlackGlyph()
            glyph.bboxPt = nil
            return page(widthPt: widthPt, heightPt: heightPt, dpi: dpi, glyphs: [glyph])
        }

        static func cleanWithClasses(
            _ classNames: [String], widthPt: Double, heightPt: Double, dpi: Int,
        ) -> OMRPageLabels {
            let glyphs = classNames.map { name -> OMRPageLabels.Glyph in
                var glyph = noteheadBlackGlyph()
                glyph.className = name
                return glyph
            }
            return page(widthPt: widthPt, heightPt: heightPt, dpi: dpi, glyphs: glyphs)
        }

        private static func noteheadBlackGlyph() -> OMRPageLabels.Glyph {
            OMRPageLabels.Glyph(
                className: "noteheadBlack",
                bboxPt: [36, 68, 48, 76],
                originPt: [36, 72],
                advancePt: 12,
                renderedSizePt: 8,
                fontSizePt: 0,
            )
        }

        private static func page(
            widthPt: Double, heightPt: Double, dpi: Int, glyphs: [OMRPageLabels.Glyph],
        ) -> OMRPageLabels {
            OMRPageLabels(
                schema: 1,
                page: OMRPageLabels.Page(index: 0, widthPt: widthPt, heightPt: heightPt),
                image: OMRPageLabels.Image(
                    file: "page.png", dpi: dpi,
                    labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                    sourceSizePx: nil,
                ),
                glyphs: glyphs, paths: [], beams: [], curves: [], texts: [],
                census: OMRPageLabels.Census(
                    glyphsByClass: Dictionary(
                        grouping: glyphs, by: \.className,
                    ).mapValues(\.count),
                    texts: 0,
                ),
            )
        }
    }

    struct OMRPrepSchemaTests {
        @Test func encodingIsCanonicalAndRepeatable() throws {
            let page = OMRPrepPage.sample()
            let a = try OMRPrepSchema.encodeCanonical(page)
            let b = try OMRPrepSchema.encodeCanonical(page)
            #expect(a == b)
            let text = try #require(String(data: a, encoding: .utf8))
            // Sorted keys, so a diff of two prep files is a content diff.
            let glyphs = try #require(text.range(of: "\"glyphs\"")).upperBound
            let advance = try #require(
                text.range(of: "\"advance_px\"", range: glyphs ..< text.endIndex),
            ).lowerBound
            let className = try #require(
                text.range(of: "\"class\"", range: glyphs ..< text.endIndex),
            ).lowerBound
            #expect(advance < className)
        }

        @Test func itRoundTripsThroughJSON() throws {
            let page = OMRPrepPage.sample()
            let decoded = try JSONDecoder().decode(
                OMRPrepPage.self, from: OMRPrepSchema.encodeCanonical(page),
            )
            #expect(decoded == page)
        }
    }

    struct OMRPrepPNGTests {
        @Test func aGrayBitmapSurvivesTheRoundTripExactly() throws {
            var bitmap = RasterTestBitmaps.blank(widthPx: 9, heightPx: 7, dpi: 300)
            // 63 pixels: `i % 256` alone stays 0...62 (i never reaches
            // 256), so it never exercises 255 — the PAPER value this
            // exact codec is calibrated around (`RasterTestBitmaps`'s own
            // "0 = ink, 255 = paper" convention) and the value the codec
            // gate P3d-G2 rests on. `i * 4` spreads the covered range
            // much wider (0...248); the explicit last-pixel assignment
            // guarantees 255 itself is covered.
            for i in 0 ..< bitmap.pixels.count {
                bitmap.pixels[i] = UInt8((i * 4) % 256)
            }
            bitmap.pixels[bitmap.pixels.count - 1] = 255
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("omr-prep-test-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            try OMRPrepPNG.write(bitmap, to: url)
            let back = try OMRPrepPNG.read(url)
            // Byte-exact, because this file IS the training input and the
            // inference path must reproduce it (gate P3d-G2).
            #expect(back.pixels == bitmap.pixels)
            #expect(back.width == 9)
            #expect(back.height == 7)
        }
    }
#endif
