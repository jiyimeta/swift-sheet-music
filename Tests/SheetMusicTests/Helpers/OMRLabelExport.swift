#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation
    import PDFKit
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// PDF → page labels (spec §6.6). Forced-Tier-1 walk + dual-walk
    /// codepoint pairing + ToUnicode-inversion ink bboxes. Test-side
    /// only; zero Sources/ changes (spec §4.3).
    ///
    /// LABELS ARE AUTHORITATIVE, so only Tier 1 (SMuFL PUA codepoint) may
    /// name a class. Two things hold that line:
    ///   * Tier 4 (shape matching) is off — `walkDocument`'s
    ///     `enableShapeMatching` defaults to false and is never passed here.
    ///   * Tier 2 (glyph name) keys off `characterCode`, which the CMap
    ///     path never supplies, so it cannot answer for a Type0 font.
    /// A PDF that reaches the classifier by any OTHER path (a simple font,
    /// where Tier 2 does answer) is detected by the probe walk and
    /// QUARANTINED — see `walkProblems`. A quietly-wrong label is worse
    /// than a missing document, because later gates treat these as truth.
    ///
    /// Glyphs Tier 1 cannot name are NOT dropped and NOT guessed: they keep
    /// their `unknownXXXX` class name and therefore appear in the page
    /// census, which is the per-page visibility channel for Tier-1 misses.
    @MainActor
    enum OMRLabelExport {
        struct DocumentExport {
            var pages: [OMRPageLabels]
            /// Non-empty ⇒ quarantine this document (recorded in the
            /// dataset manifest by the harness); pages may still be
            /// partially present for forensics but must not ship.
            var problems: [String]
        }

        static func export(pdfData: Data, dpi: Int) throws -> DocumentExport {
            let document = try PDFImporter.openDocument(pdfData)
            // Walk A (truth): Tier 1 authoritative, routing anchored to
            // the PUA range so A and B promote the identical glyph set.
            let truth = try PDFImporter.walkDocument(
                document, anchorMusicGlyphsToPUARange: true,
            )
            // Walk B (probe): Tier 1 disabled → every music glyph's
            // semantic is `.unknown(rawCodepoint)` on the CMap path.
            let probe = try PDFImporter.walkDocument(
                document, disableSMuFLCodepointTier: true,
                anchorMusicGlyphsToPUARange: true,
            )
            guard let paired = pairCodepoints(
                truth: truth.content.glyphs, probe: probe.content.glyphs,
            ) else {
                return DocumentExport(pages: [], problems: [
                    "dual-walk glyph count mismatch (truth "
                        + "\(truth.content.glyphs.count) vs probe "
                        + "\(probe.content.glyphs.count)) — simple-font or "
                        + "non-MuseScore PDF; cannot label",
                ])
            }
            var problems = walkProblems(paired)
            let codepoints = codepointIndex(paired)
            let outlines = OutlineResolver(document: document)
            var pages: [OMRPageLabels] = []
            for pageIndex in 0 ..< document.pageCount {
                guard let size = truth.pageSizes[pageIndex] else {
                    problems.append("page \(pageIndex): no mediaBox size")
                    continue
                }
                pages.append(OMRLabelSchema.pageLabels(
                    walked: truth.content, pageIndex: pageIndex,
                    pageSize: size, dpi: dpi,
                    imageFile: "page_\(pageIndex).png",
                    inkBBox: { glyph in
                        guard let codepoint = codepoints[glyph]?.first,
                              let em = outlines.emBox(
                                  pageIndex: pageIndex, codepoint: codepoint,
                              )
                        else { return nil }
                        return inkBBox(
                            outlineAt1000: em,
                            origin: glyph.geometry.origin,
                            renderedSize: glyph.geometry.renderedSize,
                        )
                    },
                ))
            }
            return DocumentExport(pages: pages, problems: problems)
        }

        /// Document-level rejections derived from the paired walks. Both
        /// are "this is not a Tier-1-labelable SMuFL vector score", which
        /// must quarantine rather than emit half-trusted labels.
        private static func walkProblems(
            _ paired: [(glyph: ClassifiedGlyph, codepoint: UInt32?)],
        ) -> [String] {
            var problems: [String] = []
            if paired.isEmpty {
                problems.append(
                    "no music glyph reached the classifier — "
                        + "not a SMuFL vector score; cannot label",
                )
            }
            if paired.contains(where: { $0.codepoint == nil }) {
                problems.append(
                    "probe walk answered a non-unknown semantic "
                        + "(a heuristic tier classified these glyphs, so the "
                        + "labels are not Tier-1 authoritative); affected glyphs "
                        + "carry no codepoint and no bbox",
                )
            }
            return problems
        }

        /// Codepoint(s) per distinct glyph VALUE. `pageLabels` hands the
        /// bbox closure a `ClassifiedGlyph`, not its index, so the pairing
        /// has to be re-keyed by value; `ClassifiedGlyph` is `Hashable` and
        /// its geometry carries origin + page, so a collision means two
        /// truly identical draws — for which `.first` (append order = walk
        /// order) is the same answer either way. Deterministic despite the
        /// dictionary: only the VALUE is read, never the iteration order.
        private static func codepointIndex(
            _ paired: [(glyph: ClassifiedGlyph, codepoint: UInt32?)],
        ) -> [ClassifiedGlyph: [UInt32]] {
            var out: [ClassifiedGlyph: [UInt32]] = [:]
            for pair in paired {
                if let codepoint = pair.codepoint {
                    out[pair.glyph, default: []].append(codepoint)
                }
            }
            return out
        }

        /// Per-page PUA-codepoint → glyph-outline lookup, built lazily and
        /// cached (a page's outlines repeat thousands of times).
        ///
        /// BEST EFFORT BY CONSTRUCTION: a page may carry no `/ToUnicode`,
        /// a font may ship no embedded program, and `CGFont` refuses some
        /// programs (bare CFF, damaged subsets). Every one of those returns
        /// nil rather than a zero rect, which `pageLabels` writes as a JSON
        /// `null` `bbox_pt` — counted and printed by the batch harness as
        /// `bboxMissing`. There is deliberately no fabricated fallback box.
        final class OutlineResolver {
            private let document: PDFDocument?
            private var indexByPage: [Int: [UInt32: OutlineRef]] = [:]
            private var emBoxCache: [Int: [UInt32: CGRect?]] = [:]

            struct OutlineRef {
                var font: CTFont
                var glyphID: CGGlyph
            }

            init(document: PDFDocument) {
                self.document = document
            }

            /// TEST SEAM. Preseed the per-page index so the outline half of
            /// the chain — CID-as-glyph-ID → `CTFontCreatePathForGlyph` →
            /// `boundingBoxOfPath`, plus the empty-path guard and the cache
            /// — is exercisable against a REAL embedded font program without
            /// a Type0/Identity-H PDF, which `PDFFixtureBuilder` cannot
            /// write. Pages absent from the seed resolve to an empty index.
            init(preseeded indexByPage: [Int: [UInt32: OutlineRef]]) {
                document = nil
                self.indexByPage = indexByPage
            }

            /// Outline bbox at CTFont size 1000, or nil when unreachable.
            func emBox(pageIndex: Int, codepoint: UInt32) -> CGRect? {
                if let hit = emBoxCache[pageIndex]?[codepoint] { return hit }
                var result: CGRect?
                if let ref = index(pageIndex: pageIndex)[codepoint],
                   let path = CTFontCreatePathForGlyph(ref.font, ref.glyphID, nil),
                   !path.isEmpty
                {
                    result = path.boundingBoxOfPath
                }
                emBoxCache[pageIndex, default: [:]][codepoint] = result
                return result
            }

            private func index(pageIndex: Int) -> [UInt32: OutlineRef] {
                if let cached = indexByPage[pageIndex] { return cached }
                var index: [UInt32: OutlineRef] = [:]
                if let document, let cgPage = document.page(at: pageIndex)?.pageRef {
                    index = OMRLabelExport.buildIndex(
                        cmaps: PDFImporter.extractFontCMaps(cgPage: cgPage).cmaps,
                        fonts: PDFImporter.extractEmbeddedFonts(cgPage: cgPage),
                    )
                }
                indexByPage[pageIndex] = index
                return index
            }
        }

        /// PUA scalar → (`CTFont`, glyph ID) for ONE page's font resources.
        /// Split out of `OutlineResolver` so it can be driven from a
        /// synthetic CMap over a real embedded program (see the seam on
        /// `init(preseeded:)`).
        ///
        /// For Identity-H fonts the CID **is** the glyph ID, which is why
        /// the CID goes straight into `CGGlyph` — a subset font does not
        /// keep a usable Unicode cmap, so `CTFontGetGlyphsForCharacters`
        /// must not be used here (measured fact, recorded in
        /// `GlyphClassifier.swift`).
        nonisolated static func buildIndex(
            cmaps: [String: PDFImporter.ToUnicodeCMap],
            fonts: [String: PDFImporter.EmbeddedFont],
        ) -> [UInt32: OutlineResolver.OutlineRef] {
            var index: [UInt32: OutlineResolver.OutlineRef] = [:]
            let inverted = invertCMaps(cmaps)
            var fontByResource: [String: CTFont] = [:]
            // Sorted scalars: the result is order-independent, but sorting
            // removes any doubt about hash-order effects.
            for scalar in inverted.keys.sorted() {
                guard let ref = inverted[scalar] else { continue }
                if fontByResource[ref.resource] == nil,
                   let program = fonts[ref.resource]?.program,
                   let ctFont = makeCTFont(program: program)
                {
                    fontByResource[ref.resource] = ctFont
                }
                guard let ctFont = fontByResource[ref.resource] else { continue }
                index[scalar] = OutlineResolver.OutlineRef(
                    font: ctFont, glyphID: CGGlyph(truncatingIfNeeded: ref.cid),
                )
            }
            return index
        }
    }
#endif
