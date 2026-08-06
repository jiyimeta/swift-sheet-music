#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    struct OMRLabelExportUnitTests {
        @Test func inkBBoxScalesTheEmBoxAboutTheOrigin() {
            // Outline at CTFont size 1000: a notehead-ish box.
            let em = CGRect(x: 0, y: -250, width: 590, height: 500)
            let box = OMRLabelExport.inkBBox(
                outlineAt1000: em,
                origin: CGPoint(x: 100, y: 400),
                renderedSize: 10,
            )
            #expect(abs(box.minX - 100.0) < 1e-9)
            #expect(abs(box.minY - (400 - 2.5)) < 1e-9)
            #expect(abs(box.width - 5.9) < 1e-9)
            #expect(abs(box.height - 5.0) < 1e-9)
        }

        @Test func invertCMapsPrefersSortedResourceOrderAndPUAOnly() throws {
            let f0 = try PDFImporter.ToUnicodeCMap(table: [
                5: [#require(Unicode.Scalar(0xE0A4))], // noteheadBlack
                6: [#require(Unicode.Scalar(0x41))], // 'A' — not PUA, ignored
            ])
            let f1 = try PDFImporter.ToUnicodeCMap(table: [
                9: [#require(Unicode.Scalar(0xE0A4))], // duplicate mapping, loses to F0
                7: [#require(Unicode.Scalar(0xE050))], // clefG
            ])
            let inverted = OMRLabelExport.invertCMaps(["F0": f0, "F1": f1])
            #expect(inverted[0xE0A4]?.resource == "F0")
            #expect(inverted[0xE0A4]?.cid == 5)
            #expect(inverted[0xE050]?.resource == "F1")
            #expect(inverted[0xE050]?.cid == 7)
            #expect(inverted[0x41] == nil)
        }

        @Test func pairCodepointsZipsEqualCountsAndRejectsMismatch() throws {
            func glyph(_ semantic: SMuFLSemantic, x: CGFloat) -> ClassifiedGlyph {
                ClassifiedGlyph(
                    geometry: GlyphGeometry(
                        origin: CGPoint(x: x, y: 0), advance: 5,
                        renderedSize: 10, pageIndex: 0, fontSize: 100,
                    ),
                    semantic: semantic,
                )
            }
            let truth = [glyph(.noteheadBlack, x: 1), glyph(.clefG, x: 2)]
            let probe = [glyph(.unknown(0xE0A4), x: 1), glyph(.unknown(0xE050), x: 2)]
            let paired = try #require(OMRLabelExport.pairCodepoints(truth: truth, probe: probe))
            #expect(paired.map(\.codepoint) == [0xE0A4, 0xE050])
            #expect(paired.map(\.glyph.semantic) == [.noteheadBlack, .clefG])
            #expect(OMRLabelExport.pairCodepoints(truth: truth, probe: [probe[0]]) == nil)
        }

        @Test func pairCodepointsPassesNilThroughWhenProbeSemanticIsNotUnknown() throws {
            func glyph(_ semantic: SMuFLSemantic) -> ClassifiedGlyph {
                ClassifiedGlyph(
                    geometry: GlyphGeometry(
                        origin: .zero, advance: 5, renderedSize: 10,
                        pageIndex: 0, fontSize: 100,
                    ),
                    semantic: semantic,
                )
            }
            // A probe glyph some tier still answered (should not happen on
            // the CMap path, but must not crash): codepoint is nil, the
            // export records a problem and emits the glyph without a bbox.
            let paired = try #require(OMRLabelExport.pairCodepoints(
                truth: [glyph(.noteheadBlack)], probe: [glyph(.noteheadBlack)],
            ))
            #expect(paired[0].codepoint == nil)
        }

        /// End-to-end smoke on a CoreGraphics fixture: such a PDF takes the
        /// SIMPLE-FONT path, so it cannot be labeled — export must REJECT
        /// it with a problem, not crash and not emit half labels.
        ///
        /// NAMED FOR WHAT IT ACTUALLY ASSERTS: this fixture is rejected
        /// because NO music glyph is promoted, not because the two walks
        /// disagree on count. The count-mismatch branch of `pairCodepoints`
        /// is covered only by the unit test above — do not read this test
        /// as covering it.
        @MainActor
        @Test func fixturePDFIsRejectedBecauseNoMusicGlyphIsPromoted() throws {
            let data = try PDFFixtureBuilder.build(
                glyphs: [PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: #require(UnicodeScalar(0xE0A4)),
                    fontName: "Helvetica",
                    fontSize: 32, origin: CGPoint(x: 100, y: 400),
                )],
                paths: (0 ..< 5).map {
                    PDFFixtureBuilder.PathPlacement(
                        origin: CGPoint(x: 50, y: 400 + CGFloat($0) * 8),
                        kind: .horizontal(width: 400),
                    )
                },
                dropToUnicodeCMaps: true,
            )
            let result = try OMRLabelExport.export(pdfData: data, dpi: 300)
            // Measured: this fixture promotes ZERO music glyphs under the
            // PUA anchor (CoreGraphics' simple-font encoding does not decode
            // back to U+E0A4), so the rejection arrives via the "no music
            // glyph reached the classifier" problem rather than via a count
            // mismatch. Either way it must never emit labels.
            #expect(!result.problems.isEmpty)
        }

        /// Ink-bbox recovery is BEST EFFORT. Every CoreGraphics-written
        /// fixture maps its music codes to Latin scalars in `/ToUnicode`
        /// (see `PDFFixtureBuilder.strippingToUnicodeCMaps`), so nothing
        /// inverts back to a PUA codepoint — the resolver must answer nil,
        /// never a fabricated zero rect. Asked twice to exercise the cache.
        @MainActor
        @Test func outlineResolverAnswersNilWhenNoPUAMappingExists() throws {
            let data = try PDFFixtureBuilder.build(
                glyphs: [PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: #require(UnicodeScalar(0xE0A4)),
                    fontName: "Bravura",
                    fontSize: 32, origin: CGPoint(x: 100, y: 700),
                )],
            )
            let document = try PDFImporter.openDocument(data)
            let resolver = OMRLabelExport.OutlineResolver(document: document)
            #expect(resolver.emBox(pageIndex: 0, codepoint: 0xE0A4) == nil)
            #expect(resolver.emBox(pageIndex: 0, codepoint: 0xE0A4) == nil)
        }

        /// Not `private`: it is read from the `.enabled(if:)` trait below.
        static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register
        }

        /// Both faces, exactly as `PDFSyntheticFontProgramTests` builds
        /// them — that file already proves this fixture carries a real
        /// Bravura CFF subset program.
        @MainActor
        private static func twoFaceFixture() -> Data {
            PDFFixtureBuilder.build(glyphs: [
                PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "\u{E0A4}", // noteheadBlack
                    fontName: "Bravura", fontSize: 32,
                    origin: CGPoint(x: 100, y: 700),
                ),
                PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "a", fontName: "Helvetica",
                    fontSize: 12, origin: CGPoint(x: 100, y: 650),
                ),
            ])
        }

        /// THE POSITIVE PATH. `PDFFixtureBuilder` cannot write a
        /// Type0/Identity-H PDF, but the delicate half of the chain does not
        /// need one: real embedded program → `makeCTFont` → CID-as-glyph-ID
        /// → `CTFontCreatePathForGlyph` → `boundingBoxOfPath` → `inkBBox`.
        /// Driven here with a SYNTHETIC `/ToUnicode` CMap over the real
        /// Bravura CFF subset the fixture embeds, so a stub `emBox` returning
        /// nil could not pass.
        ///
        /// Gated with `.enabled(if:)` rather than the house
        /// `guard bravuraAvailable else { return }`, so a host without
        /// Bravura reports this as SKIPPED instead of as a green test that
        /// asserted nothing — the one outcome that would defeat its purpose.
        @MainActor
        @Test(.enabled(if: OMRLabelExportUnitTests.bravuraAvailable))
        func recoversARealInkBBoxFromAnEmbeddedProgram() throws {
            let document = try PDFImporter.openDocument(Self.twoFaceFixture())
            let cgPage = try #require(document.page(at: 0)?.pageRef)
            let fonts = PDFImporter.extractEmbeddedFonts(cgPage: cgPage)
            // Subset-embedded faces are renamed "ABCDEF+Bravura"; match the
            // suffix after any "+". Only one resource matches, so `first` is
            // deterministic despite the dictionary.
            let resource = try #require(fonts.first { entry in
                (
                    entry.value.baseFont.split(separator: "+").last.map(String.init)
                        ?? entry.value.baseFont
                ) == "Bravura"
            })
            let program = try #require(resource.value.program)
            let font = try #require(makeCTFont(program: program))
            let glyphCount = CTFontGetGlyphCount(font)
            // Lowest glyph ID with a real outline — ascending, deterministic.
            let inked = try #require((1 ..< glyphCount).first { glyph in
                guard let path = CTFontCreatePathForGlyph(font, CGGlyph(glyph), nil)
                else { return false }
                return !path.isEmpty
            })
            // Synthetic Identity-H CMap: that glyph ID AS the CID, mapped to
            // a PUA scalar. A second scalar points past the end of the subset
            // — no outline — to pin the guard that turns that into nil.
            let cmap = try PDFImporter.ToUnicodeCMap(table: [
                UInt32(inked): [#require(Unicode.Scalar(0xE0A4))],
                UInt32(glyphCount) + 500: [#require(Unicode.Scalar(0xE0A5))],
            ])
            let index = OMRLabelExport.buildIndex(cmaps: [resource.key: cmap], fonts: fonts)
            #expect(index[0xE0A4]?.glyphID == CGGlyph(inked))
            #expect(index[0xE0A5] != nil) // indexed, but has no outline

            let resolver = OMRLabelExport.OutlineResolver(preseeded: [0: index])
            let em = try #require(resolver.emBox(pageIndex: 0, codepoint: 0xE0A4))
            // An outline read at CTFont size 1000 is em-scaled — hundreds of
            // units, not ~10. This is what couples `makeCTFont`'s `size: 1000`
            // default to `inkBBox`'s /1000 divisor: if either drifted, these
            // bounds fail rather than silently scaling every label's bbox.
            #expect(em.width > 50)
            #expect(em.height > 50)
            #expect(em.width < 3000)
            #expect(em.height < 3000)
            #expect(resolver.emBox(pageIndex: 0, codepoint: 0xE0A5) == nil)
            #expect(resolver.emBox(pageIndex: 7, codepoint: 0xE0A4) == nil)

            let ink = OMRLabelExport.inkBBox(
                outlineAt1000: em, origin: CGPoint(x: 100, y: 700), renderedSize: 32,
            )
            // Page-space, at the drawn origin, no bigger than ~2 em at 32 pt.
            #expect(ink.width > 0)
            #expect(ink.height > 0)
            #expect(ink.width < 64)
            #expect(ink.height < 64)
            #expect(abs(ink.midX - 100) < 64)
            #expect(abs(ink.midY - 700) < 64)
        }
    }

    /// Batch label export over a dataset (spec §6.6). No-op unless
    /// OMR_LABEL_EXPORT=1. Prints, never asserts (house harness style,
    /// spec §8.3) — except that a missing OMR_DATA_ROOT with the gate ON
    /// is a recorded Issue (the caller asked for a run and gave no data).
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_LABEL_EXPORT"] == "1"))
    struct OMRLabelExportHarness {
        @MainActor
        @Test func exportLabelsForEveryRender() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_LABEL_EXPORT=1 but OMR_DATA_ROOT is unset")
                return
            }
            let fm = FileManager.default
            let renderDirs = try fm.contentsOfDirectory(atPath: root)
                .sorted()
                .map { "\(root)/\($0)" }
                .filter { fm.fileExists(atPath: "\($0)/render.json") }
            print("[export] \(renderDirs.count) render dirs under \(root)")
            for dir in renderDirs {
                exportOneRender(dir: dir)
            }
        }

        /// One render directory: `render.json` names the PDF and the raster
        /// dpi; the labels land beside them. Prints one `[SUMMARY]` line per
        /// directory and never throws — a bad directory must not abort the
        /// batch.
        @MainActor
        private func exportOneRender(dir: String) {
            let tag = "[\((dir as NSString).lastPathComponent)]"
            do {
                let renderData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/render.json"))
                guard let render = try JSONSerialization
                    .jsonObject(with: renderData) as? [String: Any],
                    let pdfName = render["pdf"] as? String,
                    let dpi = render["dpi"] as? Int
                else {
                    print("\(tag)[SUMMARY] FAIL-BAD-RENDER-JSON")
                    return
                }
                let pdfData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(pdfName)"))
                let result = try OMRLabelExport.export(pdfData: pdfData, dpi: dpi)
                if !result.problems.isEmpty {
                    print(
                        "\(tag)[SUMMARY] QUARANTINE "
                            + result.problems.joined(separator: " | "),
                    )
                    return
                }
                try write(result.pages, to: dir, tag: tag)
            } catch {
                print("\(tag)[SUMMARY] FAIL-THREW \(error)")
            }
        }

        /// Write the canonical label files and print the census that makes
        /// both failure modes visible: `bboxMissing` (no outline reachable)
        /// and `tier1Missing` (a PUA glyph Tier 1 could not name, carried
        /// as an `unknownXXXX` class rather than guessed).
        ///
        /// One caveat on `tier1Missing`: `OMRLabelClassNames.className(for:)`
        /// also answers `"unknown0000"` from its `default:` branch for a
        /// `SMuFLSemantic` case added upstream and not yet in the detector
        /// table. That is VOCABULARY DRIFT, not a Tier-1 miss — a nonzero
        /// count whose class is exactly `unknown0000` should send you to
        /// Task 1's table, not to the classifier.
        private func write(_ pages: [OMRPageLabels], to dir: String, tag: String) throws {
            var glyphTotal = 0
            var bboxMissing = 0
            var tier1Missing = 0
            for page in pages {
                glyphTotal += page.glyphs.count
                bboxMissing += page.glyphs.count { $0.bboxPt == nil }
                tier1Missing += page.census.glyphsByClass
                    .filter { $0.key.hasPrefix("unknown") }
                    .values.reduce(0, +)
                let out = URL(fileURLWithPath: "\(dir)/page_\(page.page.index).labels.json")
                try OMRLabelSchema.encodeCanonical(page).write(to: out)
            }
            print(
                "\(tag)[SUMMARY] pages=\(pages.count) glyphs=\(glyphTotal) "
                    + "bboxMissing=\(bboxMissing) tier1Missing=\(tier1Missing)",
            )
        }
    }
#endif
